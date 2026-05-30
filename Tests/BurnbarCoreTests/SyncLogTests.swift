import Foundation
import XCTest
@testable import BurnbarCore

/// Verifies the 2.5.3 ``SyncLog`` helper: it appends a timestamped structured
/// line under an *injected* base directory (never the real `~/Library/Logs`),
/// creates the `Burnbar/` log folder on first use, appends rather than truncates,
/// and — the load-bearing privacy invariant — emits only timing / status / count
/// fields, never user content or a filesystem path.
final class SyncLogTests: XCTestCase {

    /// A unique temp base directory per test, removed in `tearDown`, so the suite
    /// never touches the real user Logs folder.
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-synclog-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        baseDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - File location

    func testResolvesLogPathUnderInjectedBaseDirectory() {
        let log = SyncLog(baseDirectory: baseDirectory)

        XCTAssertEqual(
            log.directory,
            baseDirectory.appendingPathComponent("Burnbar", isDirectory: true)
        )
        XCTAssertEqual(log.fileURL.lastPathComponent, "sync.log")
        // The real Logs folder must never appear — tests write to temp only.
        XCTAssertFalse(log.fileURL.path.contains("/Library/Logs/Burnbar"))
    }

    func testDefaultBaseDirectoryIsUserLibraryLogs() {
        // Documents the production location without writing to it.
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        XCTAssertEqual(SyncLog.defaultBaseDirectory(), expected)
    }

    // MARK: - Append behaviour

    func testAppendCreatesDirectoryAndWritesTimestampedLine() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let log = SyncLog(baseDirectory: baseDirectory, now: { fixedNow })

        // Precondition: nothing exists yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.directory.path))

        log.append("force-resync done write=wrote machines=3 duration_ms=420")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: log.directory.path),
            "append must create the Burnbar/ log directory"
        )
        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        let line = try XCTUnwrap(contents.split(separator: "\n").first.map(String.init))

        // "<iso8601-utc> <detail>"
        XCTAssertEqual(line, "\(SyncLog.timestamp(fixedNow)) force-resync done write=wrote machines=3 duration_ms=420")
        XCTAssertTrue(line.hasPrefix("2023-11-14T"), "line begins with the ISO-8601 UTC timestamp, got: \(line)")
        XCTAssertTrue(contents.hasSuffix("\n"), "each entry is newline-terminated")
    }

    func testAppendIsAdditiveNotTruncating() throws {
        let log = SyncLog(baseDirectory: baseDirectory, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        log.append("force-resync start")
        log.append("force-resync done write=wrote machines=2 duration_ms=88")

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 2, "the second append must not overwrite the first")
        XCTAssertTrue(lines[0].hasSuffix("force-resync start"))
        XCTAssertTrue(lines[1].hasSuffix("force-resync done write=wrote machines=2 duration_ms=88"))
    }

    // MARK: - Privacy (load-bearing)

    func testLoggedLineContainsNoUserContentOrPathFields() throws {
        let log = SyncLog(baseDirectory: baseDirectory)

        // A representative resync result line, produced exactly as ForceResync
        // composes it, then logged.
        let detail = ForceResync.resultDetail(
            for: ForceResyncResult(writeOutcome: .wrote(at: Date()), machinesRead: 3, durationMillis: 420)
        )
        log.append(detail)

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)

        // None of the ⚠ "never read / never upload" fields (CLAUDE.md /
        // data-sources.md) may ever surface in a sync-log line.
        let forbidden = [
            "message.content", "first_user_message", "preview", "title",
            "cwd", "git_branch", "git_origin_url", "git_", "/Users/", "/Library/", ".jsonl"
        ]
        for needle in forbidden {
            XCTAssertFalse(
                contents.contains(needle),
                "sync.log must never contain '\(needle)' — got: \(contents)"
            )
        }

        // Positively: it carries only the allowlisted structured fields.
        XCTAssertTrue(contents.contains("write=wrote"))
        XCTAssertTrue(contents.contains("machines=3"))
        XCTAssertTrue(contents.contains("duration_ms=420"))
    }

    func testInjectedAppendPrimitiveIsUsed() {
        // The append primitive is injectable so a test can avoid the disk
        // entirely; assert the helper routes through it.
        let captured = CapturedLines()
        let log = SyncLog(
            baseDirectory: baseDirectory,
            now: { Date(timeIntervalSince1970: 0) },
            appendLine: { line, file in captured.add(line: line, file: file) }
        )

        log.append("force-resync start")

        XCTAssertEqual(captured.lines.count, 1)
        XCTAssertEqual(captured.files.first, log.fileURL)
        XCTAssertEqual(
            captured.lines.first,
            "\(SyncLog.timestamp(Date(timeIntervalSince1970: 0))) force-resync start\n"
        )
    }

    // MARK: - Helpers

    /// Thread-safe capture of the lines/files handed to an injected append
    /// primitive.
    private final class CapturedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [String] = []
        private var storedFiles: [URL] = []

        func add(line: String, file: URL) {
            lock.lock(); defer { lock.unlock() }
            storedLines.append(line)
            storedFiles.append(file)
        }

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return storedLines
        }

        var files: [URL] {
            lock.lock(); defer { lock.unlock() }
            return storedFiles
        }
    }
}
