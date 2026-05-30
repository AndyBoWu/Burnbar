import Foundation
import XCTest
@testable import BurnbarCore

/// Verifies the 2.5.3 ``ForceResync`` driver: it performs the WRITE strictly
/// before the READ (so the re-read reflects the freshly written file), reports the
/// machines-read count + duration, and appends exactly two structured `SyncLog`
/// lines (a `start` and a `done`) carrying only status / count / timing — never
/// content or paths.
final class ForceResyncTests: XCTestCase {

    /// Records the order in which the injected write/read closures ran, so a test
    /// can assert write-then-read.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []

        func record(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
    }

    /// Captures `SyncLog` appends in memory so a test can assert the structured
    /// lines without touching the disk.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []

        func add(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }

        /// A ``SyncLog`` whose append primitive feeds this capture (and never
        /// touches the filesystem).
        func makeLog(now: @escaping @Sendable () -> Date) -> SyncLog {
            let capture = self
            return SyncLog(
                baseDirectory: URL(fileURLWithPath: "/dev/null"),
                now: now,
                appendLine: { line, _ in capture.add(line) }
            )
        }
    }

    // MARK: - Ordering (DoD)

    func testRunsWriteBeforeRead() async {
        let order = OrderLog()

        let resync = ForceResync(
            write: {
                order.record("write")
                return .wrote(at: Date(timeIntervalSince1970: 1_700_000_000))
            },
            readMachineCount: {
                order.record("read")
                return 3
            },
            log: LogCapture().makeLog(now: { Date(timeIntervalSince1970: 0) })
        )

        _ = await resync.run()

        XCTAssertEqual(order.events, ["write", "read"], "the write must complete before the re-read begins")
    }

    func testReturnsWriteOutcomeMachinesReadAndDuration() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Clock steps: run() reads `now()` at start, then again at the end.
        let clock = SteppingClock(instants: [start, start.addingTimeInterval(0.42)])
        let outcome = SyncWriteOutcome.wrote(at: start)

        let resync = ForceResync(
            write: { outcome },
            readMachineCount: { 4 },
            log: LogCapture().makeLog(now: { start }),
            now: { clock.next() }
        )

        let result = await resync.run()

        XCTAssertEqual(result.writeOutcome, outcome)
        XCTAssertEqual(result.machinesRead, 4)
        XCTAssertEqual(result.durationMillis, 420, "0.42s elapsed → 420ms")
    }

    // MARK: - Logging

    func testAppendsStartAndDoneLines() async {
        let capture = LogCapture()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        let resync = ForceResync(
            write: { .wrote(at: fixedNow) },
            readMachineCount: { 3 },
            log: capture.makeLog(now: { fixedNow }),
            now: { fixedNow }
        )

        _ = await resync.run()

        XCTAssertEqual(capture.lines.count, 2, "exactly one start line and one done line")
        XCTAssertTrue(capture.lines[0].hasSuffix("force-resync start\n"))
        XCTAssertTrue(
            capture.lines[1].hasSuffix("force-resync done write=wrote machines=3 duration_ms=0\n"),
            "got: \(capture.lines[1])"
        )
    }

    func testFailedWriteLogsErrorStatusButStillReads() async {
        let order = OrderLog()
        let capture = LogCapture()

        let resync = ForceResync(
            write: {
                order.record("write")
                return .failed(reason: "disk full")
            },
            readMachineCount: {
                order.record("read")
                return 2
            },
            log: capture.makeLog(now: { Date(timeIntervalSince1970: 0) })
        )

        let result = await resync.run()

        // A failed write must not abort the re-read — the user still wants the
        // freshest fleet view we can produce.
        XCTAssertEqual(order.events, ["write", "read"])
        XCTAssertEqual(result.machinesRead, 2)
        XCTAssertTrue(capture.lines[1].contains("write=failed"))
        XCTAssertTrue(capture.lines[1].contains("error=\"disk full\""))
    }

    func testSkippedWriteIsLoggedWithReason() {
        let detail = ForceResync.resultDetail(
            for: ForceResyncResult(
                writeOutcome: .skipped(.iCloudUnavailable(reason: "iCloud Drive disabled / signed out.")),
                machinesRead: 0,
                durationMillis: 12
            )
        )
        XCTAssertTrue(detail.contains("write=skipped_icloud_unavailable"))
        XCTAssertTrue(detail.contains("machines=0"))
        XCTAssertTrue(detail.contains("error=\"iCloud Drive disabled / signed out.\""))
    }

    // MARK: - Privacy

    func testLoggedDetailContainsNoContentOrPathFields() {
        // Even a hostile error reason (embedding a quote, a path, content) must be
        // sanitized into a single safe structured field.
        let detail = ForceResync.resultDetail(
            for: ForceResyncResult(
                writeOutcome: .failed(reason: "boom \"quote\"\nsecond line /Users/me/secret"),
                machinesRead: 1,
                durationMillis: 5
            )
        )

        // No newline can break the single-line structure.
        XCTAssertFalse(detail.contains("\n"), "the structured line must stay single-line")
        // Quotes inside the reason are neutralized so the field stays well-formed.
        XCTAssertFalse(detail.contains("\"quote\""))
        // None of the never-log field names appear.
        for needle in ["message.content", "first_user_message", "preview", "title", "git_", "cwd"] {
            XCTAssertFalse(detail.contains(needle))
        }
    }

    // MARK: - Helpers

    /// A clock that returns successive injected instants, repeating the last one
    /// once exhausted.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private let instants: [Date]
        private var index = 0

        init(instants: [Date]) {
            self.instants = instants
        }

        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = instants[min(index, instants.count - 1)]
            index += 1
            return value
        }
    }
}
