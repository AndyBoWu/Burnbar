import SQLite3
import XCTest
@testable import BurnbarCore

/// Tests for mapping Codex's aggregated rows into ``UsageRecord`` (1.3.3).
///
/// Like ``CodexThreadsReaderTests`` these build tiny throwaway SQLite databases
/// in a temp directory via a *separate* read-write connection (never the reader
/// under test), so they never touch the user's real `~/.codex/state_5.sqlite`
/// and commit no real data. The committed anonymized fixture is also exercised
/// when present, to prove DoD parity end-to-end.
final class CodexUsageProviderTests: XCTestCase {
    // MARK: - Temp DB helpers

    private func makeTempDatabase(
        setup: (OpaquePointer) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-codex-usage-tests", isDirectory: true)
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

    /// `threads` DDL with a content/path column (`title`) present, to prove the
    /// mapping never surfaces it into a `UsageRecord`.
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

    private func makeProvider(over url: URL) -> CodexUsageProvider {
        CodexUsageProvider(reader: CodexThreadsReader(reader: CodexSQLiteReader(url: url)))
    }

    // MARK: - Field mapping (the Codex granularity caveat)

    func testMapsEachBucketToCodexUsageRecord() throws {
        let dayA = 1_748_476_800_000 // 2025-05-29 00:00:00 UTC
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model, title) VALUES
              ('a', \(dayA), 100, 'gpt-5', 'secret prompt one'),
              ('b', \(dayA), 50,  'gpt-5', 'secret prompt two'),
              ('c', \(dayA), 7,   'gpt-5-codex', 'secret prompt three');
            """)
        }
        let records = try makeProvider(over: url).usageRecords()

        XCTAssertEqual(records.count, 2, "two (day, model) buckets")

        let byModel = Dictionary(uniqueKeysWithValues: records.map { ($0.model, $0) })
        let gpt5 = try XCTUnwrap(byModel["gpt-5"])
        XCTAssertEqual(gpt5.provider, .codex)
        XCTAssertEqual(gpt5.day, "2025-05-29", "day used verbatim from the reader")
        XCTAssertEqual(gpt5.inputTokens, 150, "tokens_used total maps to inputTokens")

        // The Codex caveat: the other three token fields stay nil, never zero.
        XCTAssertNil(gpt5.outputTokens)
        XCTAssertNil(gpt5.cacheReadTokens)
        XCTAssertNil(gpt5.cacheCreationTokens)

        // Cost is applied later by CostCalculator (Epic 1.4), not in the parser.
        XCTAssertNil(gpt5.costUSD)
    }

    /// ``UsageRecord/totalTokens`` treats nil fields as absent, so a Codex
    /// record's total equals its inputTokens (the bucket's tokens).
    func testRecordTotalEqualsInputTokensForCodex() throws {
        let day = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(day), 4242, 'gpt-5');
            """)
        }
        let record = try XCTUnwrap(try makeProvider(over: url).usageRecords().first)
        XCTAssertEqual(record.totalTokens, 4242)
        XCTAssertEqual(record.totalTokens, record.inputTokens)
    }

    // MARK: - DoD: total matches threads sum

    func testTotalInputTokensMatchesThreadsSum() throws {
        let dayA = 1_748_476_800_000 // 2025-05-29 UTC
        let dayB = 1_748_563_200_000 // 2025-05-30 UTC
        let rawTokens = [100, 50, 7, 13, 900]
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(dayA), 100, 'gpt-5'),
              ('b', \(dayA), 50,  'gpt-5'),
              ('c', \(dayA), 7,   'gpt-5-codex'),
              ('d', \(dayB), 13,  'gpt-5'),
              ('e', \(dayB), 900, 'gpt-5-codex');
            """)
        }
        let records = try makeProvider(over: url).usageRecords()

        // Every row's whole token total lives in inputTokens, so summing
        // inputTokens across all records must equal the sum of every thread's
        // tokens_used (the DoD).
        let mappedSum = records.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(mappedSum, rawTokens.reduce(0, +))

        // And totalTokens agrees, since the other fields are nil.
        let totalSum = records.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(totalSum, rawTokens.reduce(0, +))
    }

    // MARK: - Provider + ordering

    func testAllRecordsAreCodexProvider() throws {
        let day = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(day), 1, 'gpt-5'),
              ('b', \(day), 2, 'gpt-5-codex');
            """)
        }
        let records = try makeProvider(over: url).usageRecords()
        XCTAssertTrue(records.allSatisfy { $0.provider == .codex })
    }

    func testRecordsSortedByDayThenModel() throws {
        let dayEarlier = 1_748_476_800_000 // 2025-05-29 UTC
        let dayLater = 1_748_563_200_000 // 2025-05-30 UTC
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            // Reader emits day DESC; provider re-sorts ascending by (day, model).
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(dayLater),   20, 'gpt-5-codex'),
              ('b', \(dayLater),   10, 'gpt-5'),
              ('c', \(dayEarlier), 30, 'gpt-5');
            """)
        }
        let records = try makeProvider(over: url).usageRecords()
        XCTAssertEqual(
            records.map { "\($0.day)|\($0.model)" },
            ["2025-05-29|gpt-5", "2025-05-30|gpt-5", "2025-05-30|gpt-5-codex"]
        )
    }

    func testNullModelSurfacesAsUnknownModel() throws {
        let day = 1_748_476_800_000
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
            self.exec(handle, """
            INSERT INTO threads (id, created_at_ms, tokens_used, model) VALUES
              ('a', \(day), 42, NULL);
            """)
        }
        let record = try XCTUnwrap(try makeProvider(over: url).usageRecords().first)
        XCTAssertEqual(record.model, "unknown", "NULL model coalesces to 'unknown' upstream")
        XCTAssertEqual(record.inputTokens, 42)
    }

    // MARK: - Empty / absent → [] (not an error)

    func testEmptyThreadsTableYieldsNoRecords() throws {
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
        }
        XCTAssertEqual(try makeProvider(over: url).usageRecords(), [])
    }

    func testMissingDatabasePropagatesReaderError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        let provider = makeProvider(over: url)
        XCTAssertFalse(provider.databaseExists)
        XCTAssertThrowsError(try provider.usageRecords()) { error in
            guard
                case let CodexThreadsReaderError.reader(inner) = error,
                case .fileNotFound = inner
            else {
                return XCTFail("expected .reader(.fileNotFound), got \(error)")
            }
        }
    }

    // MARK: - Convenience pass-throughs

    func testDatabasePathAndExistsReflectUnderlyingReader() throws {
        let url = try makeTempDatabase { handle in
            self.createThreadsTable(handle)
        }
        let provider = makeProvider(over: url)
        XCTAssertEqual(provider.databasePath, url.path)
        XCTAssertTrue(provider.databaseExists)
    }

    // MARK: - Anonymized committed fixture (DoD parity, real query shape)

    private func anonymizedFixtureURL(file: StaticString = #filePath) -> URL? {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let testsRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let fixture = testsRoot
            .appendingPathComponent("Fixtures/Codex/anonymized_state.sqlite")
        return FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil
    }

    func testAnonymizedFixtureMapsToExpectedUsageRecords() throws {
        guard let url = anonymizedFixtureURL() else {
            throw XCTSkip("anonymized Codex fixture not present")
        }
        let records = try makeProvider(over: url).usageRecords()

        // Fixture: two gpt-5 rows on one day (100 + 50) plus a NULL-created_at
        // row (999 tokens) filtered out → one aggregated bucket of 150.
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.provider, .codex)
        XCTAssertEqual(record.model, "gpt-5")
        XCTAssertEqual(record.inputTokens, 150)
        XCTAssertNil(record.outputTokens)
        XCTAssertNil(record.cacheReadTokens)
        XCTAssertNil(record.cacheCreationTokens)
        XCTAssertNil(record.costUSD)

        // DoD: mapped total matches the threads (post-filter) sum.
        XCTAssertEqual(records.reduce(0) { $0 + $1.inputTokens }, 150)
    }
}
