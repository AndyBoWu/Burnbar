import XCTest
@testable import BurnbarCore

/// Tests for the Claude cache + delta merge (sub-ticket 1.2.4).
///
/// Each test wires a fixture-backed ``StatsCacheReader`` and a temp-dir
/// ``JSONLDeltaScanner`` into a ``ClaudeUsageProvider`` with a fixed clock and a
/// fixed-timezone calendar, so "today" and the JSONL midnight cutoff are fully
/// deterministic. Fixtures under `Tests/Fixtures/Claude/` are reused as-is.
final class ClaudeUsageProviderTests: XCTestCase {

    // MARK: - Deterministic time

    /// UTC calendar so the formatted "today" key and the scanner's local-midnight
    /// cutoff agree regardless of where the test runs.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    /// Fixed "now". `1_780_000_000` is 2026-05-28T08:26:40Z → today key 2026-05-28
    /// in UTC, which does *not* collide with the committed cache fixture (history
    /// ends 2026-05-24).
    private static let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
    private static let todayKey = "2026-05-28"

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Fixture helpers

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurnbarCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/Claude")
    }

    /// Writes raw JSON into a temp stats-cache file and returns a reader for it.
    private func cacheReader(json: String) throws -> StatsCacheReader {
        let url = tempRoot.appendingPathComponent("stats-cache-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return StatsCacheReader(fileURL: url)
    }

    /// Reader pointed at the committed `stats-cache.json` fixture (copied into the
    /// temp dir so the original is never mutated).
    private func fixtureCacheReader() throws -> StatsCacheReader {
        let source = Self.fixturesDir.appendingPathComponent("stats-cache.json")
        let dest = tempRoot.appendingPathComponent("stats-cache.json")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        return StatsCacheReader(fileURL: dest)
    }

    /// Reader for a non-existent cache file → `readOrEmpty()` yields an empty cache.
    private func missingCacheReader() -> StatsCacheReader {
        StatsCacheReader(fileURL: tempRoot.appendingPathComponent("does-not-exist.json"))
    }

    /// Installs a JSONL fixture under `projects/<dir>/<name>` with the given mtime
    /// and returns a scanner rooted at the temp projects dir.
    @discardableResult
    private func installTodayDelta(
        fixture: String = "single-model.jsonl",
        projectDir: String = "-Users-anon-Repos-demo",
        as destName: String? = nil,
        modified: Date = fixedNow
    ) throws -> URL {
        let projects = tempRoot.appendingPathComponent("projects", isDirectory: true)
        let dir = projects.appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(destName ?? fixture)
        try FileManager.default.copyItem(at: Self.fixturesDir.appendingPathComponent(fixture), to: dest)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dest.path)
        return dest
    }

    private func scanner() -> JSONLDeltaScanner {
        JSONLDeltaScanner(
            projectsDirectory: tempRoot.appendingPathComponent("projects", isDirectory: true),
            calendar: Self.utcCalendar,
            now: { Self.fixedNow }
        )
    }

    private func provider(cache: StatsCacheReader, scanner: JSONLDeltaScanner) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            statsCacheReader: cache,
            deltaScanner: scanner,
            calendar: Self.utcCalendar,
            now: { Self.fixedNow }
        )
    }

    // MARK: - Happy path

    func testMergesCacheHistoryWithTodayDelta() throws {
        try installTodayDelta()
        let records = try provider(cache: fixtureCacheReader(), scanner: scanner()).usageRecords()

        // History days (31 in fixture, all before today) + today's single model.
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { $0.provider == .claude })
        XCTAssertTrue(records.allSatisfy { $0.costUSD == nil }, "costing is applied later (Epic 1.4)")

        // Today is present with the full breakdown from the JSONL delta.
        let todayOpus = try XCTUnwrap(
            records.first { $0.day == Self.todayKey && $0.model == "claude-opus-4-7" }
        )
        XCTAssertEqual(todayOpus.inputTokens, 10)
        XCTAssertEqual(todayOpus.outputTokens, 200)
        XCTAssertEqual(todayOpus.cacheReadTokens, 50000)
        XCTAssertEqual(todayOpus.cacheCreationTokens, 31924)

        // A historical day from the cache is present and mapped aggregate→input.
        let histDay = try XCTUnwrap(
            records.first { $0.day == "2026-04-24" && $0.model == "claude-opus-4-7" }
        )
        XCTAssertEqual(histDay.inputTokens, 100_000)
        XCTAssertNil(histDay.outputTokens)
        XCTAssertNil(histDay.cacheReadTokens)
        XCTAssertNil(histDay.cacheCreationTokens)
        XCTAssertEqual(histDay.totalTokens, 100_000)
    }

    /// DoD: total for today equals the manual sum of today's `message.usage`.
    func testTodayTotalMatchesManualJSONLSum() throws {
        try installTodayDelta()
        let records = try provider(cache: fixtureCacheReader(), scanner: scanner()).usageRecords()

        let todayTotal = records
            .filter { $0.day == Self.todayKey }
            .reduce(0) { $0 + $1.totalTokens }

        // single-model.jsonl: input 2+8, output 137+63, cacheRead 0+50000, cacheCreate 31824+100.
        let manual = (2 + 8) + (137 + 63) + (0 + 50000) + (31824 + 100)
        XCTAssertEqual(todayTotal, manual)
    }

    func testRecordsAreSortedByDayThenModel() throws {
        try installTodayDelta()
        let records = try provider(cache: fixtureCacheReader(), scanner: scanner()).usageRecords()
        let keys = records.map { "\($0.day)|\($0.model)" }
        XCTAssertEqual(keys, keys.sorted(), "records must be in (day, model) order")
    }

    // MARK: - Double-count guard

    /// When `lastComputedDate == today`, the cache already carries a today entry.
    /// The provider must drop it and use the live JSONL delta only — never sum
    /// both.
    func testCacheTodayEntryIsReplacedByLiveDeltaNotSummed() throws {
        let json = """
        {
          "version": 3,
          "lastComputedDate": "\(Self.todayKey)",
          "dailyModelTokens": [
            { "date": "2026-05-27", "tokensByModel": { "claude-opus-4-7": 99 } },
            { "date": "\(Self.todayKey)", "tokensByModel": { "claude-opus-4-7": 777777 } }
          ],
          "modelUsage": {}
        }
        """
        try installTodayDelta()
        let records = try provider(cache: cacheReader(json: json), scanner: scanner()).usageRecords()

        // Exactly one record for today's opus, and it carries the LIVE value, not
        // the cache's stale 777777, and not their sum.
        let todayOpus = records.filter { $0.day == Self.todayKey && $0.model == "claude-opus-4-7" }
        XCTAssertEqual(todayOpus.count, 1, "today must not be duplicated across cache and delta")
        XCTAssertEqual(todayOpus.first?.inputTokens, 10)
        XCTAssertNotEqual(todayOpus.first?.inputTokens, 777_777)
        XCTAssertNotEqual(todayOpus.first?.inputTokens, 777_777 + 10)

        // The genuine history day survives.
        XCTAssertEqual(
            records.first { $0.day == "2026-05-27" }?.inputTokens, 99
        )
    }

    /// Even with no live delta today, a cache "today" entry is still dropped (so a
    /// stale recomputed cache never leaks a phantom today total).
    func testCacheTodayEntryDroppedEvenWhenNoLiveDelta() throws {
        let json = """
        {
          "version": 3,
          "lastComputedDate": "\(Self.todayKey)",
          "dailyModelTokens": [
            { "date": "\(Self.todayKey)", "tokensByModel": { "claude-opus-4-7": 5000 } }
          ],
          "modelUsage": {}
        }
        """
        // No installTodayDelta(): projects dir is empty.
        let records = try provider(cache: cacheReader(json: json), scanner: scanner()).usageRecords()
        XCTAssertTrue(
            records.allSatisfy { $0.day != Self.todayKey },
            "cache's today entry must be dropped; no live delta means no today records"
        )
    }

    // MARK: - Empty / degraded sources

    func testEmptyCacheAndNoDeltaYieldsNoRecords() throws {
        // Missing cache file (readOrEmpty) + missing projects dir.
        let records = try provider(cache: missingCacheReader(), scanner: scanner()).usageRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testFreshMachineWithOnlyTodayDelta() throws {
        // No cache yet, but Claude Code has been used today.
        try installTodayDelta()
        let records = try provider(cache: missingCacheReader(), scanner: scanner()).usageRecords()
        XCTAssertEqual(records.count, 1)
        let opus = try XCTUnwrap(records.first)
        XCTAssertEqual(opus.provider, .claude)
        XCTAssertEqual(opus.day, Self.todayKey)
        XCTAssertEqual(opus.model, "claude-opus-4-7")
        XCTAssertEqual(opus.inputTokens, 10)
    }

    func testCacheOnlyWhenNothingUsedToday() throws {
        // History present, but no JSONL touched today.
        let yesterday = Self.utcCalendar.date(byAdding: .day, value: -1, to: Self.fixedNow)!
        try installTodayDelta(modified: yesterday) // stale → ignored by scanner
        let records = try provider(cache: fixtureCacheReader(), scanner: scanner()).usageRecords()

        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(
            records.allSatisfy { $0.day != Self.todayKey },
            "no usage today → no today records, only cache history"
        )
        // All history records carry the aggregate→input mapping (nil breakdown).
        XCTAssertTrue(records.allSatisfy { $0.outputTokens == nil })
    }

    /// A genuinely corrupt cache file still surfaces as an error (only the
    /// "no cache yet" case is swallowed by `readOrEmpty`).
    func testCorruptCacheThrows() throws {
        let reader = try cacheReader(json: "{ not valid json")
        XCTAssertThrowsError(
            try provider(cache: reader, scanner: scanner()).usageRecords()
        )
    }
}
