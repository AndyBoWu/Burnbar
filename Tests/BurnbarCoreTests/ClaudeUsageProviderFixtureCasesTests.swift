import XCTest
@testable import BurnbarCore

/// End-to-end ``ClaudeUsageProvider`` fixture cases for sub-ticket 1.2.5.
///
/// The 1.2.5 Definition of Done calls out three canonical provider-level
/// scenarios driven by the committed, anonymized fixtures under
/// `Tests/Fixtures/Claude/`:
///
/// - **empty** — no history and a session with no assistant usage → no records;
/// - **single-model** — one model's today delta merged onto cache history;
/// - **multi-model** — several models in one today delta (including an
///   unnamed-model line → `"unknown"`), merged onto cache history.
///
/// These are asserted here as three explicitly named tests so the DoD is
/// self-evident, without modifying the broader merge/double-count suite in
/// `ClaudeUsageProviderTests`. Each test wires a fixture-backed
/// ``StatsCacheReader`` and a temp-dir ``JSONLDeltaScanner`` into a
/// ``ClaudeUsageProvider`` with a fixed clock and fixed-timezone calendar, so
/// "today" and the JSONL midnight cutoff are fully deterministic and never read
/// the developer's real `~/.claude` directory.
final class ClaudeUsageProviderFixtureCasesTests: XCTestCase {
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
            .appendingPathComponent("ClaudeUsageProviderFixtureCasesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Fixture helpers

    /// `Tests/BurnbarCoreTests/<thisFile>` → `Tests/Fixtures/Claude`.
    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurnbarCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/Claude")
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

    /// Reader for a non-existent cache file → `readOrEmpty()` yields an empty
    /// cache (the "fresh machine, no history yet" state).
    private func missingCacheReader() -> StatsCacheReader {
        StatsCacheReader(fileURL: tempRoot.appendingPathComponent("does-not-exist.json"))
    }

    /// Installs a JSONL fixture under `projects/<dir>/<fixture>` stamped to
    /// today's `fixedNow` so the scanner's mtime gate includes it.
    @discardableResult
    private func installTodayDelta(
        fixture: String,
        projectDir: String = "-Users-anon-Repos-demo"
    ) throws -> URL {
        let projects = tempRoot.appendingPathComponent("projects", isDirectory: true)
        let dir = projects.appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fixture)
        try FileManager.default.copyItem(at: Self.fixturesDir.appendingPathComponent(fixture), to: dest)
        try FileManager.default.setAttributes([.modificationDate: Self.fixedNow], ofItemAtPath: dest.path)
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

    // MARK: - Case 1: empty

    /// Empty case: no cache history and a session with no assistant usage
    /// (`empty-session.jsonl` is summary + user lines only) yields **no records**.
    func testCase_empty_noCacheAndEmptySessionYieldsNoRecords() throws {
        try installTodayDelta(fixture: "empty-session.jsonl")
        let records = try provider(cache: missingCacheReader(), scanner: scanner()).usageRecords()

        XCTAssertTrue(
            records.isEmpty,
            "no history + a session with no assistant `message.usage` must produce no UsageRecords"
        )
    }

    // MARK: - Case 2: single-model

    /// Single-model case: `single-model.jsonl` carries two `claude-opus-4-7`
    /// assistant lines (and a user line that must be ignored), merged on top of
    /// the cache history. Today's record carries the full four-field breakdown;
    /// the cache history days map their per-day aggregate to `inputTokens` with a
    /// `nil` breakdown.
    func testCase_singleModel_todayDeltaMergedWithCacheHistory() throws {
        try installTodayDelta(fixture: "single-model.jsonl")
        let records = try provider(cache: try fixtureCacheReader(), scanner: scanner()).usageRecords()

        XCTAssertTrue(records.allSatisfy { $0.provider == .claude })
        XCTAssertTrue(records.allSatisfy { $0.costUSD == nil }, "costing is applied later (Epic 1.4)")

        // Exactly one model is present for today, and it is opus with the summed
        // four-field breakdown (input 2+8, output 137+63, cacheRead 0+50000,
        // cacheCreate 31824+100).
        let todayRecords = records.filter { $0.day == Self.todayKey }
        XCTAssertEqual(todayRecords.map(\.model), ["claude-opus-4-7"], "single model today")

        let todayOpus = try XCTUnwrap(todayRecords.first)
        XCTAssertEqual(todayOpus.inputTokens, 10)
        XCTAssertEqual(todayOpus.outputTokens, 200)
        XCTAssertEqual(todayOpus.cacheReadTokens, 50_000)
        XCTAssertEqual(todayOpus.cacheCreationTokens, 31_924)

        // DoD (1.2.4 carried into 1.2.5): today's total equals the manual sum of
        // today's `message.usage`.
        let manual = (2 + 8) + (137 + 63) + (0 + 50_000) + (31_824 + 100)
        XCTAssertEqual(todayOpus.totalTokens, manual)

        // Cache history is present and untouched by the delta: a historical opus
        // day maps its aggregate → inputTokens with a nil breakdown.
        let histOpus = try XCTUnwrap(
            records.first { $0.day == "2026-04-24" && $0.model == "claude-opus-4-7" }
        )
        XCTAssertEqual(histOpus.inputTokens, 100_000)
        XCTAssertNil(histOpus.outputTokens)
        XCTAssertNil(histOpus.cacheReadTokens)
        XCTAssertNil(histOpus.cacheCreationTokens)
    }

    // MARK: - Case 3: multi-model

    /// Multi-model case: `multi-model.jsonl` carries opus, two sonnet lines, an
    /// assistant line with no `model` (→ `"unknown"`), a `summary` line and a
    /// garbled line (both ignored), plus a trailing opus line with no `usage`
    /// (skipped). Each model becomes its own today ``UsageRecord``, merged on top
    /// of the cache history.
    func testCase_multiModel_perModelTodayRecordsMergedWithCacheHistory() throws {
        try installTodayDelta(fixture: "multi-model.jsonl")
        let records = try provider(cache: try fixtureCacheReader(), scanner: scanner()).usageRecords()

        XCTAssertTrue(records.allSatisfy { $0.provider == .claude })

        // Today has exactly three models: opus, sonnet, and the unnamed-model line
        // bucketed as "unknown".
        let todayRecords = records.filter { $0.day == Self.todayKey }
        XCTAssertEqual(
            Set(todayRecords.map(\.model)),
            ["claude-opus-4-7", "claude-sonnet-4-6", "unknown"]
        )

        // opus: only the first opus line has usage; the trailing usage-less opus
        // line is skipped.
        let opus = try XCTUnwrap(todayRecords.first { $0.model == "claude-opus-4-7" })
        XCTAssertEqual(opus.inputTokens, 10)
        XCTAssertEqual(opus.outputTokens, 20)
        XCTAssertEqual(opus.cacheCreationTokens, 200)
        XCTAssertEqual(opus.cacheReadTokens, 1_000)

        // sonnet: two lines summed; the second omits cache fields (→ 0).
        let sonnet = try XCTUnwrap(todayRecords.first { $0.model == "claude-sonnet-4-6" })
        XCTAssertEqual(sonnet.inputTokens, 12) // 5 + 7
        XCTAssertEqual(sonnet.outputTokens, 43) // 40 + 3
        XCTAssertEqual(sonnet.cacheReadTokens, 300) // 300 + (missing → 0)
        XCTAssertEqual(sonnet.cacheCreationTokens, 0)

        // unknown: the single model-less assistant line.
        let unknown = try XCTUnwrap(todayRecords.first { $0.model == "unknown" })
        XCTAssertEqual(unknown.inputTokens, 1)
        XCTAssertEqual(unknown.outputTokens, 1)

        // Today's grand total equals the manual sum across all three models.
        let todayTotal = todayRecords.reduce(0) { $0 + $1.totalTokens }
        let manual =
            (10 + 20 + 200 + 1_000) // opus
            + (12 + 43 + 300 + 0) // sonnet
            + (1 + 1) // unknown
        XCTAssertEqual(todayTotal, manual)

        // Cache history co-exists: a multi-model history day exposes each of its
        // per-model aggregates as its own record (aggregate → inputTokens).
        let histDay = "2026-04-24"
        XCTAssertEqual(records.first { $0.day == histDay && $0.model == "claude-opus-4-7" }?.inputTokens, 100_000)
        XCTAssertEqual(records.first { $0.day == histDay && $0.model == "claude-sonnet-4-6" }?.inputTokens, 50_000)
        XCTAssertEqual(
            records.first { $0.day == histDay && $0.model == "claude-haiku-4-5-20251001" }?.inputTokens,
            2_000
        )
    }
}
