import XCTest
@testable import BurnbarCore

/// Tests for the Claude `stats-cache.json` reader (sub-ticket 1.2.1).
///
/// Uses the committed, anonymized fixture under `Tests/Fixtures/Claude/`. To stay
/// independent of how the test bundle ships resources, the fixture is located via
/// `#filePath` (repo-relative) and copied into a temp dir for each test that
/// needs a concrete `fileURL`.
final class StatsCacheReaderTests: XCTestCase {
    // MARK: - Fixture location

    /// Repo root, derived from this file's path:
    /// `<root>/Tests/BurnbarCoreTests/StatsCacheReaderTests.swift`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurnbarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static var fixtureURL: URL {
        repoRoot
            .appendingPathComponent("Tests/Fixtures/Claude/stats-cache.json")
    }

    private func loadFixtureData() throws -> Data {
        try Data(contentsOf: Self.fixtureURL)
    }

    /// Writes arbitrary bytes to a unique temp file and registers cleanup.
    private func writeTempFile(_ data: Data, name: String = "stats-cache.json") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnbarStatsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    // MARK: - Happy path / Definition of Done

    func testDecodesFixtureWithAtLeastThirtyDaysOfDailyModelTokens() throws {
        let url = try writeTempFile(try loadFixtureData())
        let cache = try StatsCacheReader(fileURL: url).read()

        XCTAssertEqual(cache.version, 3)
        XCTAssertEqual(cache.lastComputedDate, "2026-05-24")
        XCTAssertGreaterThanOrEqual(
            cache.dailyModelTokens.count, 30,
            "DoD: returns >= 30 days of per-model token counts"
        )
    }

    func testDailyModelTokensExposeRawModelIdsAndCounts() throws {
        let url = try writeTempFile(try loadFixtureData())
        let cache = try StatsCacheReader(fileURL: url).read()

        let firstDay = try XCTUnwrap(cache.dailyModelTokens.first)
        XCTAssertEqual(firstDay.date, "2026-04-24")
        XCTAssertEqual(firstDay.tokensByModel["claude-opus-4-7"], 100_000)
        // Verbatim model ids preserved (no normalization at this layer).
        XCTAssertTrue(firstDay.tokensByModel.keys.contains("claude-haiku-4-5-20251001"))
    }

    func testModelUsageDecodesAllFiveAggregateFields() throws {
        let url = try writeTempFile(try loadFixtureData())
        let cache = try StatsCacheReader(fileURL: url).read()

        let opus = try XCTUnwrap(cache.modelUsage["claude-opus-4-7"])
        XCTAssertEqual(opus.inputTokens, 63_474)
        XCTAssertEqual(opus.outputTokens, 1_592_614)
        XCTAssertEqual(opus.cacheReadInputTokens, 65_907_504)
        XCTAssertEqual(opus.cacheCreationInputTokens, 4_270_790)
        XCTAssertEqual(opus.webSearchRequests, 0)
    }

    /// The cache on real machines carries derived fields (`costUSD`,
    /// `contextWindow`, …) and sibling top-level keys (`dailyActivity`,
    /// `hourCounts`, …). Decoding must ignore them, not fail.
    func testIgnoresUnknownExtraFields() throws {
        let url = try writeTempFile(try loadFixtureData())
        let cache = try StatsCacheReader(fileURL: url).read()

        // sonnet entry in the fixture has only the modeled fields + webSearchRequests
        let sonnet = try XCTUnwrap(cache.modelUsage["claude-sonnet-4-6"])
        XCTAssertEqual(sonnet.webSearchRequests, 3)
        // opus entry additionally carries costUSD/contextWindow/maxOutputTokens — ignored.
        XCTAssertNotNil(cache.modelUsage["claude-opus-4-7"])
    }

    // MARK: - Path resolution

    func testDefaultURLResolvesUnderHomeNotHardcoded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = StatsCacheReader.defaultURL()
        XCTAssertEqual(url, home.appendingPathComponent(".claude/stats-cache.json"))
        XCTAssertTrue(url.path.hasPrefix(home.path))
        XCTAssertTrue(url.path.hasSuffix(".claude/stats-cache.json"))
    }

    // MARK: - Error / empty handling

    func testMissingFileThrowsFileNotFound() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)/stats-cache.json")
        let reader = StatsCacheReader(fileURL: missing)
        XCTAssertThrowsError(try reader.read()) { error in
            guard case StatsCacheReader.ReadError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    func testReadOrEmptyReturnsEmptyCacheWhenFileMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)/stats-cache.json")
        let cache = try StatsCacheReader(fileURL: missing).readOrEmpty()
        XCTAssertEqual(cache.version, StatsCacheReader.expectedVersion)
        XCTAssertTrue(cache.dailyModelTokens.isEmpty)
        XCTAssertTrue(cache.modelUsage.isEmpty)
        XCTAssertNil(cache.lastComputedDate)
    }

    func testCorruptJSONThrowsDecodingFailed() throws {
        let url = try writeTempFile(Data("{ not valid json".utf8))
        let reader = StatsCacheReader(fileURL: url)
        XCTAssertThrowsError(try reader.read()) { error in
            guard case StatsCacheReader.ReadError.decodingFailed = error else {
                return XCTFail("expected decodingFailed, got \(error)")
            }
        }
    }

    /// A version mismatch should warn but still decode best-effort (not throw).
    func testVersionMismatchStillDecodes() throws {
        let json = """
        {
          "version": 99,
          "lastComputedDate": "2026-05-24",
          "dailyModelTokens": [
            { "date": "2026-05-24", "tokensByModel": { "claude-opus-4-7": 5 } }
          ],
          "modelUsage": {}
        }
        """
        let url = try writeTempFile(Data(json.utf8))
        let cache = try StatsCacheReader(fileURL: url).read()
        XCTAssertEqual(cache.version, 99)
        XCTAssertEqual(cache.dailyModelTokens.count, 1)
    }

    /// A cache header written before any usage accrued (no arrays) must decode to
    /// empty collections, not fail.
    func testMissingCollectionsDecodeAsEmpty() throws {
        let json = """
        { "version": 3, "lastComputedDate": "2026-05-24" }
        """
        let url = try writeTempFile(Data(json.utf8))
        let cache = try StatsCacheReader(fileURL: url).read()
        XCTAssertTrue(cache.dailyModelTokens.isEmpty)
        XCTAssertTrue(cache.modelUsage.isEmpty)
    }
}
