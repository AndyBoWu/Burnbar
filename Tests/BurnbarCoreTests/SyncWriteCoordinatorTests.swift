import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``SyncWriteCoordinator`` with injected fakes (no real iCloud, no real
/// providers) to assert the Definition of Done: `last-write-at` advances on a
/// successful write at the expected instants, stays unchanged when iCloud is
/// unavailable or a load/write fails, and concurrent triggers never overlap.
final class SyncWriteCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory ``LastWriteStore``. A reference type guarded by a lock so it is
    /// `Sendable` and can be observed across the coordinator's actor hop.
    private final class FakeLastWriteStore: LastWriteStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date?

        func lastWriteAt() -> Date? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func setLastWriteAt(_ date: Date) {
            lock.lock(); defer { lock.unlock() }
            value = date
        }
    }

    /// One captured invocation of the write closure.
    private struct WriteCall: Equatable {
        let records: [UsageRecord]
        let directory: URL
        let machineID: String
    }

    /// Records the URLs/ids handed to the write closure so a test can assert the
    /// writer was (or was not) invoked, and how many times.
    private final class WriteSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [WriteCall] = []

        func record(_ records: [UsageRecord], _ directory: URL, _ machineID: String) {
            lock.lock(); defer { lock.unlock() }
            calls.append(WriteCall(records: records, directory: directory, machineID: machineID))
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return calls.count
        }
    }

    private static let directory = URL(fileURLWithPath: "/tmp/burnbar-test-rollups", isDirectory: true)

    private static func sampleRecords() -> [UsageRecord] {
        [
            UsageRecord(
                provider: .claude,
                model: "claude-opus-4-7",
                day: "2026-05-29",
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                costUSD: 0.01
            )
        ]
    }

    // MARK: - Success path

    func testSuccessfulWritePersistsTimestampAndCallsWriter() async {
        let store = FakeLastWriteStore()
        let spy = WriteSpy()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let records = Self.sampleRecords()
        let directory = Self.directory

        let coordinator = SyncWriteCoordinator(
            resolveLocation: { .container(directory) },
            loadRecords: { records },
            machineID: { "abc123def456abcd" },
            writeRollup: { recs, dir, id in spy.record(recs, dir, id) },
            store: store,
            now: { fixedNow }
        )

        XCTAssertNil(store.lastWriteAt(), "precondition: no timestamp before first write")

        let outcome = await coordinator.write()

        XCTAssertEqual(outcome, .wrote(at: fixedNow))
        XCTAssertEqual(store.lastWriteAt(), fixedNow, "last-write-at must advance to now() on success")
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(spy.calls.first?.machineID, "abc123def456abcd")
        XCTAssertEqual(spy.calls.first?.directory, directory)
        XCTAssertEqual(spy.calls.first?.records, records)
    }

    func testTimestampAdvancesOnEachSuccessfulWrite() async {
        let store = FakeLastWriteStore()
        // Simulate the timer firing at two successive instants (interval apart).
        let instants = [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_300) // +5 min
        ]
        let index = Counter()
        let directory = Self.directory

        let coordinator = SyncWriteCoordinator(
            resolveLocation: { .container(directory) },
            loadRecords: { [] },
            machineID: { "machineid00000000" },
            writeRollup: { _, _, _ in },
            store: store,
            now: { instants[index.next()] }
        )

        let first = await coordinator.write()
        XCTAssertEqual(first, .wrote(at: instants[0]))
        XCTAssertEqual(store.lastWriteAt(), instants[0])

        let second = await coordinator.write()
        XCTAssertEqual(second, .wrote(at: instants[1]))
        XCTAssertEqual(store.lastWriteAt(), instants[1], "the timestamp advances on the next interval write")
    }

    // MARK: - iCloud unavailable

    func testUnavailableICloudSkipsAndLeavesTimestampUnchanged() async {
        let store = FakeLastWriteStore()
        let priorTimestamp = Date(timeIntervalSince1970: 1_600_000_000)
        store.setLastWriteAt(priorTimestamp)
        let spy = WriteSpy()

        let coordinator = SyncWriteCoordinator(
            resolveLocation: { .unavailable(reason: "iCloud Drive disabled / signed out.") },
            loadRecords: { XCTFail("loadRecords must not run when iCloud is unavailable"); return [] },
            machineID: { "machineid00000000" },
            writeRollup: { recs, dir, id in spy.record(recs, dir, id) },
            store: store
        )

        let outcome = await coordinator.write()

        XCTAssertEqual(outcome, .skipped(.iCloudUnavailable(reason: "iCloud Drive disabled / signed out.")))
        XCTAssertEqual(store.lastWriteAt(), priorTimestamp, "an unavailable skip must not touch last-write-at")
        XCTAssertEqual(spy.count, 0, "nothing is written when iCloud is unavailable")
    }

    // MARK: - Failure path

    func testWriteFailureLeavesTimestampUnchanged() async {
        struct BoomError: Error {}
        let store = FakeLastWriteStore()
        let directory = Self.directory

        let coordinator = SyncWriteCoordinator(
            resolveLocation: { .fallback(directory) },
            loadRecords: { throw BoomError() },
            machineID: { "machineid00000000" },
            writeRollup: { _, _, _ in },
            store: store
        )

        let outcome = await coordinator.write()

        guard case .failed = outcome else {
            XCTFail("expected .failed, got \(outcome)")
            return
        }
        XCTAssertNil(store.lastWriteAt(), "a failed write must not record a timestamp")
    }

    // MARK: - Overlap guard

    func testConcurrentWritesDoNotOverlap() async {
        let store = FakeLastWriteStore()
        let spy = WriteSpy()
        // Hold the first write suspended at its async load step until the test
        // releases it, so the second trigger necessarily arrives mid-flight.
        let gate = AsyncGate()
        let directory = Self.directory

        let coordinator = SyncWriteCoordinator(
            resolveLocation: { .container(directory) },
            loadRecords: {
                // Suspend (without blocking the actor's thread) until released.
                await gate.wait()
                return []
            },
            machineID: { "machineid00000000" },
            writeRollup: { recs, dir, id in spy.record(recs, dir, id) },
            store: store
        )

        // Start the first write; it suspends inside loadRecords holding isWriting.
        let firstTask = Task { await coordinator.write() }
        await gate.waitUntilWaiterArrived()

        // A second trigger now arrives while the first is still in flight.
        let secondOutcome = await coordinator.write()
        XCTAssertEqual(secondOutcome, .skipped(.alreadyInFlight))

        // Release the first write and let it finish.
        await gate.open()
        let firstResult = await firstTask.value
        if case .wrote = firstResult {} else {
            XCTFail("the first write should complete, got \(firstResult)")
        }
        XCTAssertEqual(spy.count, 1, "only one write actually ran")
        XCTAssertNotNil(store.lastWriteAt(), "the completed write recorded a timestamp")
    }

    // MARK: - Test helpers

    /// Thread-safe incrementing index for the multi-instant clock fake.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    /// An async gate the in-flight write *suspends* on (never blocking a thread)
    /// until the test opens it. `waitUntilWaiterArrived()` lets the test observe
    /// that the first write has reached the suspension point — and is therefore
    /// genuinely in flight — before it triggers the second write.
    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var hasWaiterArrived = false

        /// Suspend until ``open()`` is called. Resumes immediately if already open.
        func wait() async {
            // Signal anyone awaiting the waiter's arrival.
            hasWaiterArrived = true
            for continuation in arrivalWaiters {
                continuation.resume()
            }
            arrivalWaiters.removeAll()

            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Suspend until a `wait()` caller has arrived at the gate.
        func waitUntilWaiterArrived() async {
            if hasWaiterArrived { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }

        /// Open the gate, resuming every current and future waiter.
        func open() {
            isOpen = true
            for continuation in waiters {
                continuation.resume()
            }
            waiters.removeAll()
        }
    }
}
