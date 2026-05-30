import XCTest
@testable import BurnbarCore

/// Epic 1.3.4 — locks the Codex parser end-to-end (CodexThreadsReader query +
/// CodexUsageProvider → UsageRecord mapping) against a committed, fully
/// anonymized fixture: 3 rows across 2 models and 2 days, with one (day, model)
/// pair duplicated so the SUM grouping is exercised.
final class CodexFixtureParserTests: XCTestCase {
    /// Resolve the fixture relative to this source file (same pattern as the
    /// other Codex tests), so `xcodebuild test` finds it on a clean CI checkout
    /// without SPM resource bundling.
    private func fixtureURL(file: StaticString = #filePath) -> URL {
        let testsRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()      // BurnbarCoreTests/
            .deletingLastPathComponent()      // Tests/
        return testsRoot.appendingPathComponent("Fixtures/Codex/state_5_fixture.sqlite")
    }

    private func makeReader() -> CodexThreadsReader {
        CodexThreadsReader(reader: CodexSQLiteReader(url: fixtureURL()))
    }

    func testFixtureExistsAndIsUnder20KB() throws {
        let url = fixtureURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture missing at \(url.path)")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? .max
        XCTAssertLessThan(size, 20_000, "fixture must be < 20 KB (was \(size) bytes)")
    }

    func testThreadsReaderGroupsByDayAndModel() throws {
        let rows = try makeReader().dailyModelTokens()
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.day)|\($0.model)", $0.tokens) })
        XCTAssertEqual(rows.count, 2, "two (day, model) groups expected")
        XCTAssertEqual(byKey["2026-01-10|gpt-5"], 1500, "1000 + 500 summed for the same day+model")
        XCTAssertEqual(byKey["2026-01-11|gpt-5-codex"], 2000)
    }

    func testMappingToUsageRecordHonorsCodexAsymmetry() throws {
        let records = try CodexUsageProvider(reader: makeReader()).usageRecords()
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(record.provider, .codex)
            // Codex exposes only a single tokens_used integer — the other token
            // fields must stay nil, never fabricated zeros.
            XCTAssertNil(record.outputTokens)
            XCTAssertNil(record.cacheReadTokens)
            XCTAssertNil(record.cacheCreationTokens)
            XCTAssertEqual(record.totalTokens, record.inputTokens)
        }
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ("\($0.day)|\($0.model)", $0.inputTokens) })
        XCTAssertEqual(byKey["2026-01-10|gpt-5"], 1500)
        XCTAssertEqual(byKey["2026-01-11|gpt-5-codex"], 2000)
    }

    func testGrandTotalEqualsRawSumOfThreeRows() throws {
        let records = try CodexUsageProvider(reader: makeReader()).usageRecords()
        let grand = records.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(grand, 3500, "1000 + 500 + 2000 across the 3 fixture rows")
    }
}
