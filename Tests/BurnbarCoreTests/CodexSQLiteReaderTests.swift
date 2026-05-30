import SQLite3
import XCTest
@testable import BurnbarCore

/// Tests for the read-only Codex SQLite helper (1.3.1).
///
/// These build their own tiny throwaway SQLite databases in a temp directory so
/// they never touch the user's real `~/.codex/state_5.sqlite` and commit no real
/// data. A committed anonymized fixture is also exercised when present.
final class CodexSQLiteReaderTests: XCTestCase {
    // MARK: - Temp DB helpers

    /// Creates a small SQLite DB at a unique temp path with the given DDL/inserts
    /// (via a *separate* read-write connection — never the reader under test) and
    /// returns its URL. Registers teardown cleanup, including WAL/SHM sidecars.
    private func makeTempDatabase(
        setup: (OpaquePointer) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-codex-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.sqlite")

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard openResult == SQLITE_OK, let handle else {
            XCTFail("could not create temp db (code \(openResult))", file: file, line: line)
            throw CodexReaderError.openFailed(code: openResult, message: "temp db")
        }
        setup(handle)
        sqlite3_close_v2(handle)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK, "setup SQL failed: \(sql)")
    }

    // MARK: - Path resolution

    func testDefaultDatabaseURLResolvesUnderHomeCodex() {
        let url = CodexSQLiteReader.defaultDatabaseURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Path is derived from FileManager's home dir, not hardcoded — so it
        // tracks whatever home the current user/CI agent runs as.
        XCTAssertTrue(url.path.hasPrefix(home), "must resolve under the real home dir")
        XCTAssertEqual(url.lastPathComponent, "state_5.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".codex")
    }

    // MARK: - Basic query behavior

    func testQueryReturnsRowsWithColumnAccessByNameAndIndex() throws {
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE threads (model TEXT, tokens INTEGER);")
            self.exec(handle, "INSERT INTO threads VALUES ('gpt-5', 100), ('gpt-5', 50);")
        }
        let reader = CodexSQLiteReader(url: url)
        XCTAssertTrue(reader.databaseExists)

        let rows = try reader.query(
            "SELECT model, SUM(tokens) AS total FROM threads GROUP BY model;"
        )
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["model"], .text("gpt-5"))
        XCTAssertEqual(row["total"], .integer(150))
        // index access mirrors SELECT order
        XCTAssertEqual(row[0], .text("gpt-5"))
        XCTAssertEqual(row[1], .integer(150))
        // convenience accessors used by the 1.3.2 mapping layer
        XCTAssertEqual(row["total"]?.intValue, 150)
        XCTAssertEqual(row["model"]?.stringValue, "gpt-5")
    }

    func testValueTypesAndNullPreserved() throws {
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE t (i INTEGER, r REAL, s TEXT, n TEXT);")
            self.exec(handle, "INSERT INTO t VALUES (7, 3.5, 'hello', NULL);")
        }
        let reader = CodexSQLiteReader(url: url)
        let rows = try reader.query("SELECT i, r, s, n FROM t;")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["i"], .integer(7))
        XCTAssertEqual(row["r"], .real(3.5))
        XCTAssertEqual(row["s"], .text("hello"))
        XCTAssertEqual(row["n"], .null, "present-but-NULL column is .null")
        XCTAssertNil(row["missing"], "absent column is nil (not .null)")
        XCTAssertEqual(row[99], .null, "out-of-range index is .null")
    }

    func testEmptyResultSetReturnsNoRows() throws {
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE t (a INTEGER);")
        }
        let reader = CodexSQLiteReader(url: url)
        XCTAssertEqual(try reader.query("SELECT a FROM t;").count, 0)
    }

    // MARK: - Error surfaces

    func testMissingFileThrowsFileNotFound() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        let reader = CodexSQLiteReader(url: url)
        XCTAssertFalse(reader.databaseExists)
        XCTAssertThrowsError(try reader.query("SELECT 1;")) { error in
            guard case CodexReaderError.fileNotFound = error else {
                return XCTFail("expected .fileNotFound, got \(error)")
            }
        }
    }

    func testInvalidSQLThrowsPrepareFailed() throws {
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE t (a INTEGER);")
        }
        let reader = CodexSQLiteReader(url: url)
        XCTAssertThrowsError(try reader.query("SELECT * FROM no_such_table;")) { error in
            guard case CodexReaderError.prepareFailed = error else {
                return XCTFail("expected .prepareFailed, got \(error)")
            }
        }
    }

    // MARK: - Read-only / write-lock guarantees (the heart of 1.3.1)

    /// The connection must never acquire a write lock. We prove it by attempting
    /// a write through a fresh read-only connection opened the same way the reader
    /// does and asserting SQLite rejects it with SQLITE_READONLY.
    func testConnectionIsReadOnlyAndRejectsWrites() throws {
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE t (a INTEGER);")
            self.exec(handle, "INSERT INTO t VALUES (1);")
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("/")
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed)!
        let uri = "file://\(encoded)?mode=ro&immutable=0"

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        XCTAssertEqual(openResult, SQLITE_OK)
        defer { sqlite3_close_v2(handle) }

        let writeResult = sqlite3_exec(handle, "INSERT INTO t VALUES (2);", nil, nil, nil)
        XCTAssertEqual(writeResult, SQLITE_READONLY, "read-only connection must reject writes")
    }

    /// Read-only opening must succeed even when a WAL/SHM sidecar is present
    /// (i.e. Codex is mid-write). We simulate this by switching the DB to WAL via
    /// a separate writer that leaves an uncommitted-but-flushed -wal file, then
    /// reading it back through the reader.
    func testReadsSucceedWhileWalSidecarPresent() throws {
        let url = try makeTempDatabase { handle in
            // Put the DB into WAL mode and write through it so a -wal sidecar exists.
            self.exec(handle, "PRAGMA journal_mode=WAL;")
            self.exec(handle, "CREATE TABLE threads (model TEXT, tokens INTEGER);")
            self.exec(handle, "INSERT INTO threads VALUES ('gpt-5', 10), ('gpt-5', 20);")
            // Keep WAL frames around (do not checkpoint) so the sidecar is non-trivial.
            self.exec(handle, "PRAGMA wal_checkpoint(PASSIVE);")
            self.exec(handle, "INSERT INTO threads VALUES ('gpt-5', 5);")
        }

        // Sanity: a -wal sidecar should exist next to the DB.
        let walPath = url.path + "-wal"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: walPath),
            "expected a -wal sidecar to simulate Codex mid-write"
        )

        let reader = CodexSQLiteReader(url: url)
        let rows = try reader.query("SELECT SUM(tokens) AS total FROM threads;")
        XCTAssertEqual(rows.first?["total"], .integer(35), "must see committed WAL frames")
    }

    // MARK: - Anonymized committed fixture (Burnbar's real query shape)

    /// Path to the committed anonymized fixture, resolved relative to this source
    /// file (the test bundle does not package resources).
    private func anonymizedFixtureURL(file: StaticString = #filePath) -> URL? {
        let thisFile = URL(fileURLWithPath: "\(file)")
        // .../Tests/BurnbarCoreTests/CodexSQLiteReaderTests.swift
        let testsRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let fixture = testsRoot
            .appendingPathComponent("Fixtures/Codex/anonymized_state.sqlite")
        return FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil
    }

    func testAnonymizedFixtureRunsBurnbarGroupByQuery() throws {
        guard let url = anonymizedFixtureURL() else {
            throw XCTSkip("anonymized Codex fixture not present")
        }
        let reader = CodexSQLiteReader(url: url)
        let sql = """
        SELECT
          DATE(created_at_ms / 1000, 'unixepoch') AS day,
          COALESCE(model, 'unknown') AS model,
          SUM(tokens_used) AS tokens
        FROM threads
        WHERE created_at_ms IS NOT NULL
        GROUP BY day, model
        ORDER BY day DESC;
        """
        let rows = try reader.query(sql)
        // Two rows share one day/model (100 + 50); the NULL-day row is filtered.
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(row["tokens"]?.intValue, 150)
    }
}
