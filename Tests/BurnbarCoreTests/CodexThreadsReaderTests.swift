import SQLite3
import XCTest
@testable import BurnbarCore

/// Tests for Burnbar's single Codex aggregation query (1.3.2).
///
/// These build tiny throwaway SQLite databases in a temp directory (via a
/// *separate* read-write connection, never the reader under test) so they never
/// touch the user's real `~/.codex/state_5.sqlite` and commit no real data. The
/// committed anonymized fixture is also exercised when present.
final class CodexThreadsReaderTests: XCTestCase {
    // MARK: - Temp DB helpers

    /// Creates a small SQLite DB at a unique temp path with the given DDL/inserts
    /// and returns its URL. Registers teardown cleanup (incl. WAL/SHM sidecars).
    private func makeTempDatabase(
        setup: (OpaquePointer) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-codex-threads-tests", isDirectory: true)
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

    /// Minimal `threads` DDL mirroring the columns the query touches. Deliberately
    /// includes a content/path column (`title`) to prove the query never reads it.
    private func createThreadsTable(_ handle: OpaquePointer) {
        exec(handle, """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          created_at_ms INTEGER,
          tokens_used INTEGER NOT NULL DEFAULT 0,
          model TEXT,
          title TEXT
        );
        """)
    }

    // MARK: - The SQL constant matches docs/data-sources.md verbatim

    func testAggregationSQLMatchesDataSourcesExactly() {
        let expected = """
        SELECT
          DATE(created_at_ms / 1000, 'unixepoch') AS day,
          COALESCE(model, 'unknown') AS model,
          SUM(tokens_used) AS tokens
        FROM threads
        WHERE created_at_ms IS NOT NULL
        GROUP BY day, model
        ORDER BY day DESC;
        """
        XCTAssertEqual(CodexThreadsReader.aggregationSQL, expected)
    }

    /// Privacy guard: the one SQL statement must never reference content/path
    /// columns. A failure here is a design bug, not a style nit.
    func testAggregationSQLNeverReferencesForbiddenColumns() {
        let sql = CodexThreadsReader.aggregationSQL.lowercased()
        for forbidden in [
            "title", "first_user_message", "preview", "cwd",
            "git_sha", "git_branch", "git_origin_url", "rollout_path",
        ] {
            XCTAssertFalse(
                sql.contains(forbidden),
                "query must not reference forbidden column '\(forbidden)'"
            )
        }
    }

    // MARK: - Aggregation behavior

    func testAggregatesTokensPerDayAndModel() throws {
        // 2025-05-29 00:00:00 UTC in unixepoch ms (DATE() buckets by UTC day).
        let dayA = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model, title) VALUES
              ('a', \(dayA), 100, 'gpt-5', 'secret prompt one'),
              ('b', \(dayA), 50,  'gpt-5', 'secret prompt two'),
              ('c', \(dayA), 7,   'gpt-5-codex', 'secret prompt three');
            """)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        let rows = try reader.dailyModelTokens()

        XCTAssertEqual(rows.count, 2, "two (day, model) buckets")
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.model, $0) })
        XCTAssertEqual(byModel["gpt-5"]?.tokens, 150, "100 + 50 summed")
        XCTAssertEqual(byModel["gpt-5-codex"]?.tokens, 7)
        XCTAssertEqual(byModel["gpt-5"]?.day, "2025-05-29")
    }

    func testNullModelSurfacesAsUnknownViaCoalesce() throws {
        let day = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(day), 42, NULL);
            """)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        let rows = try reader.dailyModelTokens()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.model, "unknown", "NULL model coalesces to 'unknown'")
        XCTAssertEqual(rows.first?.tokens, 42)
    }

    func testNullCreatedAtRowsAreFilteredOut() throws {
        let day = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(day), 100, 'gpt-5'),
              ('b', NULL,   999, 'gpt-5');
            """)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        let rows = try reader.dailyModelTokens()
        XCTAssertEqual(rows.count, 1, "WHERE created_at_ms IS NOT NULL drops the NULL row")
        XCTAssertEqual(rows.first?.tokens, 100, "the 999-token NULL row is excluded")
    }

    func testOrderedByDayDescending() throws {
        let dayEarlier = 1_748_476_800_000 // 2025-05-29 00:00:00 UTC
        let dayLater = 1_748_563_200_000 // 2025-05-30 00:00:00 UTC
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(dayEarlier), 10, 'gpt-5'),
              ('b', \(dayLater),   20, 'gpt-5');
            """)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        let rows = try reader.dailyModelTokens()
        XCTAssertEqual(rows.map(\.day), ["2025-05-30", "2025-05-29"], "ORDER BY day DESC")
    }

    // MARK: - Empty / no-rows cases return [] (not an error)

    func testEmptyThreadsTableReturnsEmptyArray() throws {
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        XCTAssertEqual(try reader.dailyModelTokens(), [])
    }

    func testAllNullCreatedAtReturnsEmptyArray() throws {
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', NULL, 5, 'gpt-5');
            """)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        XCTAssertEqual(try reader.dailyModelTokens(), [])
    }

    // MARK: - Error propagation

    func testMissingDatabaseThrowsReaderFileNotFound() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        XCTAssertFalse(reader.databaseExists)
        XCTAssertThrowsError(try reader.dailyModelTokens()) { error in
            guard
                case let CodexThreadsReaderError.reader(inner) = error,
                case .fileNotFound = inner
            else {
                return XCTFail("expected .reader(.fileNotFound), got \(error)")
            }
        }
    }

    func testMissingThreadsTableThrowsReaderPrepareFailed() throws {
        // A valid DB file, but no `threads` table → prepare fails.
        let url = try makeTempDatabase { handle in
            self.exec(handle, "CREATE TABLE unrelated (a INTEGER);")
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        XCTAssertThrowsError(try reader.dailyModelTokens()) { error in
            guard
                case let CodexThreadsReaderError.reader(inner) = error,
                case .prepareFailed = inner
            else {
                return XCTFail("expected .reader(.prepareFailed), got \(error)")
            }
        }
    }

    // MARK: - Convenience pass-throughs

    func testDatabasePathAndExistsReflectUnderlyingReader() throws {
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        XCTAssertEqual(reader.databasePath, url.path)
        XCTAssertTrue(reader.databaseExists)
    }

    // MARK: - Anonymized committed fixture (real query shape, DoD parity)

    /// Path to the committed anonymized fixture, resolved relative to this source
    /// file (the test bundle does not package resources).
    private func anonymizedFixtureURL(file: StaticString = #filePath) -> URL? {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let testsRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let fixture = testsRoot
            .appendingPathComponent("Fixtures/Codex/anonymized_state.sqlite")
        return FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil
    }

    func testAnonymizedFixtureProducesExpectedDailyTotals() throws {
        guard let url = anonymizedFixtureURL() else {
            throw XCTSkip("anonymized Codex fixture not present")
        }
        let reader = CodexThreadsReader(reader: CodexSQLiteReader(url: url))
        let rows = try reader.dailyModelTokens()
        // Fixture: two gpt-5 rows on one day (100 + 50) plus a NULL-created_at row
        // (999 tokens) that the WHERE clause filters out → one aggregated bucket.
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.model, "gpt-5")
        XCTAssertEqual(row.tokens, 150)
    }
}
