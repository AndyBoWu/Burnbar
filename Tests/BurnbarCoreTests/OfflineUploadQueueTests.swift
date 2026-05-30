import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises the offline upload queue (``OfflineUploadQueue``): the M3 durability
/// layer that persists validated-but-unsent leaderboard rows and drains them via
/// an injected async uploader. Covers the Definition of Done — a failed or
/// interrupted drain leaves items queued and they recover on the next drain, with
/// no duplicate `(date, provider)` ever queued or uploaded.
///
/// All I/O is injected against a per-test temp directory; no real network and no
/// `~/Library` writes are involved.
final class OfflineUploadQueueTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineUploadQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Builders

    private func record(
        date: String,
        provider: Provider = .claude,
        tokens: Int = 1000,
        costUSD: Double = 1.5
    ) -> OfflineUploadQueue.Item {
        LeaderboardRecord(date: date, provider: provider, tokens: tokens, costUSD: costUSD)
    }

    /// A fresh queue rooted at the test's temp directory (real disk I/O, no network).
    private func makeQueue() -> OfflineUploadQueue {
        OfflineUploadQueue(directory: tempDir)
    }

    // MARK: - Uploaders

    /// Records every item it is asked to upload and always succeeds.
    private actor RecordingUploader {
        private(set) var attempts: [OfflineUploadQueue.Item] = []
        func upload(_ item: OfflineUploadQueue.Item) -> Bool {
            attempts.append(item)
            return true
        }
    }

    // MARK: - Enqueue + persistence across instances

    func testEnqueuePersistsAcrossInstances() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-28", provider: .claude))
        try await queue.enqueue(record(date: "2026-05-29", provider: .codex))

        let countA = await queue.count
        XCTAssertEqual(countA, 2)

        // A brand-new instance over the same directory recovers the pending items.
        let reopened = makeQueue()
        let recovered = await reopened.items
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.map(\.id), ["2026-05-28|claude", "2026-05-29|codex"])
    }

    func testPersistedFileIsLeaderboardSafeJSONL() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-29", provider: .claude, tokens: 42, costUSD: 0.5))

        let url = await queue.fileURL
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1)

        // The on-disk row carries only the allowlisted keys — no content, paths,
        // machine ids, or model names.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["date", "provider", "tokens", "cost_usd"])
        XCTAssertNoThrow(try UploadPayloadValidator.validate(object))
    }

    // MARK: - Drain success removes

    func testDrainSuccessRemovesAllAndClearsFile() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-27"))
        try await queue.enqueue(record(date: "2026-05-28"))
        try await queue.enqueue(record(date: "2026-05-29"))

        let uploader = RecordingUploader()
        let result = try await queue.drain { await uploader.upload($0) }

        XCTAssertEqual(result.uploaded, 3)
        XCTAssertEqual(result.remaining, 0)

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)

        // Drained oldest-first.
        let attempted = await uploader.attempts
        XCTAssertEqual(attempted.map(\.date), ["2026-05-27", "2026-05-28", "2026-05-29"])

        // The emptied queue persists empty across instances.
        let reopened = makeQueue()
        let recovered = await reopened.count
        XCTAssertEqual(recovered, 0)
    }

    // MARK: - Drain failure keeps

    func testDrainFailureKeepsAllAndRecovers() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-28"))
        try await queue.enqueue(record(date: "2026-05-29"))

        // Network down: every upload fails.
        let result = try await queue.drain { _ in false }
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertEqual(result.remaining, 2)

        let stillQueued = await queue.count
        XCTAssertEqual(stillQueued, 2)

        // The failed items survive to a fresh instance and drain cleanly once the
        // network returns — no duplicates, exactly the two original rows.
        let reopened = makeQueue()
        let uploader = RecordingUploader()
        let second = try await reopened.drain { await uploader.upload($0) }
        XCTAssertEqual(second.uploaded, 2)
        XCTAssertEqual(second.remaining, 0)

        let attempted = await uploader.attempts
        XCTAssertEqual(attempted.map(\.id).sorted(), ["2026-05-28|claude", "2026-05-29|claude"])
    }

    // MARK: - Partial drain

    func testPartialDrainKeepsOnlyFailures() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-27"))
        try await queue.enqueue(record(date: "2026-05-28"))
        try await queue.enqueue(record(date: "2026-05-29"))

        // The middle item fails; the other two succeed.
        let result = try await queue.drain { item in item.date != "2026-05-28" }
        XCTAssertEqual(result.uploaded, 2)
        XCTAssertEqual(result.remaining, 1)

        let survivors = await queue.items
        XCTAssertEqual(survivors.map(\.id), ["2026-05-28|claude"])

        // A second drain (network fully back) sends exactly the one survivor — the
        // already-uploaded rows are never re-sent.
        let uploader = RecordingUploader()
        let second = try await queue.drain { await uploader.upload($0) }
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(second.remaining, 0)
        let attempted = await uploader.attempts
        XCTAssertEqual(attempted.map(\.id), ["2026-05-28|claude"])
    }

    func testInterruptedDrainPreservesUnattemptedItems() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-27"))
        try await queue.enqueue(record(date: "2026-05-28"))
        try await queue.enqueue(record(date: "2026-05-29"))

        struct CutNetwork: Error {}

        // Succeed on the first item, then the connection drops mid-drain (throw).
        await XCTAssertThrowsErrorAsync(
            try await queue.drain { item in
                if item.date == "2026-05-28" { throw CutNetwork() }
                return true
            }
        )

        // The uploaded item is gone; the in-flight and unattempted items remain and
        // recover on the next drain — no row is lost, none duplicated.
        let survivors = await queue.items
        XCTAssertEqual(survivors.map(\.id), ["2026-05-28|claude", "2026-05-29|claude"])

        let reopened = makeQueue()
        let recovered = await reopened.items
        XCTAssertEqual(recovered.map(\.id), ["2026-05-28|claude", "2026-05-29|claude"])

        let uploader = RecordingUploader()
        let result = try await reopened.drain { await uploader.upload($0) }
        XCTAssertEqual(result.uploaded, 2)
        XCTAssertEqual(result.remaining, 0)
    }

    // MARK: - Dedup on enqueue

    func testEnqueueDedupesByDateAndProvider() async throws {
        let queue = makeQueue()
        try await queue.enqueue(record(date: "2026-05-29", provider: .claude, tokens: 100, costUSD: 1.0))
        // Same (date, provider) with a re-aggregated total: replaces, never appends.
        try await queue.enqueue(record(date: "2026-05-29", provider: .claude, tokens: 250, costUSD: 2.5))
        // Same date, different provider: a distinct key, so it is queued.
        try await queue.enqueue(record(date: "2026-05-29", provider: .codex, tokens: 50, costUSD: 0.5))

        let items = await queue.items
        XCTAssertEqual(items.count, 2)

        let claude = try XCTUnwrap(items.first { $0.provider == .claude })
        XCTAssertEqual(claude.tokens, 250, "later enqueue for the same (date, provider) wins")
        XCTAssertEqual(claude.costUSD, 2.5)

        // Dedup survives a reopen: still exactly two rows, with the updated total.
        let reopened = makeQueue()
        let recovered = await reopened.items
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.first { $0.provider == .claude }?.tokens, 250)

        // Draining sends each (date, provider) exactly once.
        let uploader = RecordingUploader()
        try await reopened.drain { await uploader.upload($0) }
        let attempted = await uploader.attempts
        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(Set(attempted.map(\.id)), ["2026-05-29|claude", "2026-05-29|codex"])
    }

    // MARK: - Empty drain

    func testDrainOnEmptyQueueIsNoOp() async throws {
        let queue = makeQueue()
        let uploader = RecordingUploader()
        let result = try await queue.drain { await uploader.upload($0) }
        XCTAssertEqual(result, OfflineUploadQueue.DrainResult(uploaded: 0, remaining: 0))
        let attempted = await uploader.attempts
        XCTAssertTrue(attempted.isEmpty, "an empty queue never invokes the uploader")
    }
}

// MARK: - Async throwing assertion helper

extension XCTestCase {
    /// `XCTAssertThrowsError` for an `async` autoclosure. Fails if `expression`
    /// completes without throwing.
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ handler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail(message().isEmpty ? "Expected an error to be thrown" : message(), file: file, line: line)
        } catch {
            handler(error)
        }
    }
}
