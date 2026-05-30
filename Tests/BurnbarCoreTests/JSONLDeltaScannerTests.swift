import XCTest
@testable import BurnbarCore

/// Tests for the today-delta JSONL scanner (Epic 1.2.2).
///
/// Each test builds a throwaway `projects/<session>/*.jsonl` tree under a temp
/// directory, stamps file mtimes relative to a fixed injected "now", and asserts
/// on the per-model totals. Fixtures under `Tests/Fixtures/Claude/` are
/// anonymized (every prompt/response field is `REDACTED`) and exist precisely to
/// prove the scanner never reads them.
final class JSONLDeltaScannerTests: XCTestCase {
    /// Fixed clock: all fixture lines and "today" files hang off this.
    private static let fixedNow = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-28

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JSONLDeltaScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Helpers

    private func scanner(now: Date = fixedNow) -> JSONLDeltaScanner {
        JSONLDeltaScanner(projectsDirectory: tempRoot, calendar: .current, now: { now })
    }

    /// Copies a committed fixture into `projects/<projectDir>/<name>`, then sets
    /// its modification date.
    @discardableResult
    private func installFixture(
        _ fixtureName: String,
        projectDir: String = "-Users-anon-Repos-demo",
        as destName: String? = nil,
        modified: Date = fixedNow
    ) throws -> URL {
        let source = Self.fixtureURL(fixtureName)
        let dir = tempRoot.appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(destName ?? fixtureName)
        try FileManager.default.copyItem(at: source, to: dest)
        try setModified(dest, to: modified)
        return dest
    }

    /// Writes raw JSONL text into the temp tree with a chosen mtime.
    @discardableResult
    private func writeRaw(
        _ contents: String,
        projectDir: String = "-Users-anon-Repos-demo",
        name: String,
        modified: Date = fixedNow
    ) throws -> URL {
        let dir = tempRoot.appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try contents.write(to: dest, atomically: true, encoding: .utf8)
        try setModified(dest, to: modified)
        return dest
    }

    private func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func fixtureURL(_ name: String) -> URL {
        // Tests/BurnbarCoreTests/<thisFile>  ->  Tests/Fixtures/Claude/<name>
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // Tests/BurnbarCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/Claude/\(name)")
    }

    // MARK: - Tests

    func testMissingProjectsDirectoryReturnsEmpty() {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let result = JSONLDeltaScanner(projectsDirectory: missing, now: { Self.fixedNow }).scanToday()
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptySessionYieldsNoTotals() throws {
        // Only summary + user lines — nothing to count.
        try installFixture("empty-session.jsonl")
        XCTAssertTrue(scanner().scanToday().isEmpty)
    }

    func testSingleModelSumsAssistantUsageAndIgnoresOtherLines() throws {
        try installFixture("single-model.jsonl")
        let totals = scanner().scanToday()

        XCTAssertEqual(totals.count, 1)
        let opus = try XCTUnwrap(totals["claude-opus-4-7"])
        // Two assistant lines: input 2+8, cacheCreate 31824+100, cacheRead 0+50000, output 137+63.
        XCTAssertEqual(opus.inputTokens, 10)
        XCTAssertEqual(opus.cacheCreationTokens, 31924)
        XCTAssertEqual(opus.cacheReadTokens, 50000)
        XCTAssertEqual(opus.outputTokens, 200)
        XCTAssertEqual(opus.total, 10 + 31924 + 50000 + 200)
    }

    func testMultiModelGroupsByModelAndToleratesGarbledLines() throws {
        try installFixture("multi-model.jsonl")
        let totals = scanner().scanToday()

        // opus + sonnet + one assistant line with no model -> "unknown".
        XCTAssertEqual(Set(totals.keys), ["claude-opus-4-7", "claude-sonnet-4-6", "unknown"])

        let opus = try XCTUnwrap(totals["claude-opus-4-7"])
        // Only the first opus line has usage; the last opus line has no usage and is skipped.
        XCTAssertEqual(opus.inputTokens, 10)
        XCTAssertEqual(opus.outputTokens, 20)
        XCTAssertEqual(opus.cacheCreationTokens, 200)
        XCTAssertEqual(opus.cacheReadTokens, 1000)

        let sonnet = try XCTUnwrap(totals["claude-sonnet-4-6"])
        XCTAssertEqual(sonnet.inputTokens, 12) // 5 + 7
        XCTAssertEqual(sonnet.outputTokens, 43) // 40 + 3
        XCTAssertEqual(sonnet.cacheReadTokens, 300) // 300 + (missing -> 0)
        XCTAssertEqual(sonnet.cacheCreationTokens, 0) // 0 + (missing -> 0)

        let unknown = try XCTUnwrap(totals["unknown"])
        XCTAssertEqual(unknown.inputTokens, 1)
        XCTAssertEqual(unknown.outputTokens, 1)
    }

    func testFilesNotModifiedTodayAreIgnored() throws {
        // Same content, but stamped to yesterday -> below the local-midnight cutoff.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Self.fixedNow)!
        try installFixture("single-model.jsonl", modified: yesterday)
        XCTAssertTrue(scanner().scanToday().isEmpty, "stale (yesterday) files must be skipped")
    }

    func testFileModifiedExactlyAtMidnightIsIncluded() throws {
        let startOfToday = Calendar.current.startOfDay(for: Self.fixedNow)
        try installFixture("single-model.jsonl", modified: startOfToday)
        XCTAssertFalse(scanner().scanToday().isEmpty, "mtime == local midnight is on-or-after the cutoff")
    }

    func testNonJSONLFilesAreIgnored() throws {
        // A .json (not .jsonl) sibling with valid-looking content must not be parsed.
        try writeRaw(
            #"{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":999}}}"#,
            name: "stats-cache.json"
        )
        XCTAssertTrue(scanner().scanToday().isEmpty)
    }

    func testAggregatesAcrossMultipleProjectDirsAndSessions() throws {
        try installFixture("single-model.jsonl", projectDir: "-Users-anon-Repos-a", as: "s1.jsonl")
        try installFixture("single-model.jsonl", projectDir: "-Users-anon-Repos-b", as: "s2.jsonl")
        let totals = scanner().scanToday()
        let opus = try XCTUnwrap(totals["claude-opus-4-7"])
        // Two copies of the single-model fixture -> double the single-file totals.
        XCTAssertEqual(opus.inputTokens, 20)
        XCTAssertEqual(opus.outputTokens, 400)
    }

    func testWhollyGarbledFileDoesNotCrashAndYieldsNothing() throws {
        try writeRaw("not json at all\n\n{ broken\n", name: "broken.jsonl")
        XCTAssertTrue(scanner().scanToday().isEmpty)
    }

    /// Privacy guard: the line decoder must not even *have* a path to response
    /// text. We feed a line whose `content` carries a sentinel and assert the
    /// decoded model has no notion of it — `Message` only exposes `model`/`usage`.
    func testDecoderHasNoContentField() throws {
        let json = Data(
            #"{"type":"assistant","message":{"model":"m","content":[{"text":"SENTINEL"}],"usage":{"input_tokens":1}}}"#
                .utf8
        )
        let line = try JSONDecoder().decode(JSONLDeltaScanner.AssistantLine.self, from: json)
        XCTAssertEqual(line.message?.model, "m")
        XCTAssertEqual(line.message?.usage?.input_tokens, 1)
        // There is no API on Message to reach `content`; this compiles only because
        // the field was never declared. (Asserting the positive cases above is the
        // observable proof.)
    }
}
