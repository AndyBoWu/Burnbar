import Foundation

/// The M3 upload pipeline's durability layer (sub-ticket 3.3.5): a disk-backed,
/// deduplicated queue of validated-but-unsent leaderboard rows that survives
/// process restarts and drains when the network returns.
///
/// Uploads fail mid-flight when connectivity drops. Rather than lose a day's
/// aggregate (or double-count it on retry), the uploader enqueues each
/// leaderboard-safe row here first; the queue persists it to disk and, on the
/// next drain, replays only the rows that have not yet landed. The Definition of
/// Done is the round trip: a failed or interrupted drain leaves its rows queued,
/// and the next drain recovers them — with **no duplicates**.
///
/// ## Idempotency / dedup
/// A leaderboard row's identity is exactly `(date, provider)` — the same key the
/// server upserts on (`(github_id, date, provider)`, Epic 3.1.2). The queue keys
/// every pending item on that pair via ``LeaderboardRecord/id`` ("date|provider"),
/// so:
/// - ``enqueue(_:)`` of an already-queued `(date, provider)` **replaces** the
///   existing item rather than appending a second one (a re-aggregated day for the
///   same date overwrites the stale figure; it never queues twice), and
/// - a successful upload removes that key, so re-draining is a no-op.
///
/// Combined with the server-side upsert, a reconnect retry of a row that actually
/// did land server-side can at worst re-send it once, and the upsert collapses it
/// — never a duplicate row.
///
/// ## Persistence
/// Pending items are stored as JSON Lines (one ``LeaderboardRecord`` per line) in
/// `<directory>/upload-queue.jsonl`, written atomically (tmp → fsync → rename via
/// ``DailyRollupWriter/atomicWrite(_:to:)``) so a crash mid-rewrite never tears
/// the file — a reader sees either the prior queue or the new one, never a
/// half-written mix. The full pending set is read from disk on init, so a fresh
/// queue instance (e.g. after an app relaunch) recovers exactly what the previous
/// one left behind. Each persisted line is the leaderboard-safe `{date, provider,
/// tokens, cost_usd}` shape and nothing more — no content, paths, machine ids, or
/// model names ever reach this file (CLAUDE.md privacy thesis).
///
/// ## Concurrency
/// An `actor`: all mutation of the in-memory pending set and all disk writes are
/// serialized, so concurrent `enqueue`/`drain` calls cannot interleave a
/// half-updated queue or race the file. The directory and the I/O primitives are
/// injected, so tests drive the whole mechanism against a temp directory with no
/// real network and no `~/Library` writes.
///
/// The app-side trigger — an `NWPathMonitor` whose `.satisfied` transition calls
/// ``drain(using:)`` oldest-first via the 3.3.2 upload path — is intentionally a
/// thin wire-up in the app target, not part of this testable core. See the
/// note on ``drain(using:)``.
public actor OfflineUploadQueue {
    /// One queued unit of work: a leaderboard-safe row awaiting upload. Aliasing
    /// ``LeaderboardRecord`` keeps the queue pinned to the validated `{date,
    /// provider, tokens, cost_usd}` shape — there is no field a queued item could
    /// carry that the upload payload may not.
    public typealias Item = LeaderboardRecord

    /// The directory holding `upload-queue.jsonl`. Injected so tests point it at a
    /// temp directory; the app passes its Application Support container.
    private let directory: URL

    /// Injected durable write primitive (`Data` → file URL). Defaults to the
    /// atomic tmp → fsync → rename variant shared with the rollup writer.
    private let writeData: @Sendable (Data, URL) throws -> Void

    /// Injected read primitive (file URL → bytes, or `nil` if the file does not
    /// exist). Defaults to a `FileManager` read that maps "no file" to `nil`.
    private let readData: @Sendable (URL) throws -> Data?

    /// Pending items, newest-write-wins per `(date, provider)`. Insertion order is
    /// preserved (oldest first) so ``drain(using:)`` replays in enqueue order; a
    /// re-enqueue of an existing key updates the value in place without reordering.
    private var pending: OrderedItems

    /// The JSONL file all pending items are persisted to.
    public nonisolated var fileURL: URL {
        directory.appendingPathComponent("upload-queue.jsonl", isDirectory: false)
    }

    /// Create a queue backed by `directory`, recovering any previously persisted
    /// pending items from `<directory>/upload-queue.jsonl`.
    ///
    /// A malformed or partially written line is skipped rather than aborting
    /// recovery, so one bad row can never strand the rest of the queue. Missing
    /// file → empty queue.
    ///
    /// - Parameters:
    ///   - directory: Where `upload-queue.jsonl` lives. Created lazily on first
    ///     write; reading a missing file yields an empty queue.
    ///   - writeData: Durable write side effect. Defaults to the atomic
    ///     tmp → fsync → rename primitive.
    ///   - readData: Read side effect returning `nil` for a missing file. Defaults
    ///     to a `FileManager`-backed read.
    public init(
        directory: URL,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try DailyRollupWriter.atomicWrite(data, to: url)
        },
        readData: @escaping @Sendable (URL) throws -> Data? = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    ) {
        self.directory = directory
        self.writeData = writeData
        self.readData = readData
        let fileURL = directory.appendingPathComponent("upload-queue.jsonl", isDirectory: false)
        pending = Self.load(from: fileURL, readData: readData)
    }

    /// Number of items currently queued (after dedup). Useful for tests and the
    /// menu-bar badge.
    public var count: Int { pending.count }

    /// The pending items in drain order (oldest enqueue first). A snapshot — the
    /// queue is unaffected.
    public var items: [Item] { pending.values }

    /// Persist `item` to the queue, deduplicated by `(date, provider)`.
    ///
    /// If an item with the same `(date, provider)` is already queued, it is
    /// **replaced** (so a freshly re-aggregated total for that day supersedes the
    /// stale one) and the queue length is unchanged — the same day/provider is
    /// never queued twice. Otherwise the item is appended at the end (newest last).
    /// The full pending set is then rewritten to disk atomically before returning,
    /// so the item is durable the moment this call completes.
    ///
    /// - Parameter item: A leaderboard-safe row. Callers are expected to have
    ///   already passed it through ``UploadPayloadValidator`` (3.3.3); the type
    ///   itself guarantees only the allowlisted fields can be present.
    /// - Throws: Any error from the injected write primitive.
    public func enqueue(_ item: Item) throws {
        pending.upsert(item)
        try persist()
    }

    /// Attempt to upload every pending item via `uploader`, removing the ones that
    /// succeed and keeping the ones that fail, then persist the survivors.
    ///
    /// Drains oldest-first (enqueue order). For each item the injected async
    /// `uploader` is awaited: a `true` return means the row landed (server upsert
    /// on `(github_id, date, provider)` makes a re-send harmless), so the item is
    /// dropped; a `false` return means it did not land, so it is **kept** for a
    /// later drain. Items left over (failed, or never attempted because an earlier
    /// item threw) stay queued and persisted, so an interrupted drain recovers on
    /// the next call. The on-disk file is rewritten once, after the pass, to the
    /// exact set of survivors.
    ///
    /// This method performs no network and starts no monitor itself — the app
    /// wires an `NWPathMonitor` whose `.satisfied` transition calls this with the
    /// real 3.3.2 upload closure. Injecting `uploader` keeps the queue+dedup
    /// mechanics fully testable with no network.
    ///
    /// - Parameter uploader: Async upload of one item; `true` = uploaded (remove),
    ///   `false` = failed (keep). Awaited serially, oldest item first.
    /// - Returns: A summary of how many items were uploaded vs. left queued.
    /// - Throws: Any error from `uploader` (the in-flight item and all not-yet-
    ///   attempted items are preserved and persisted before rethrowing) or from
    ///   the injected write primitive.
    @discardableResult
    public func drain(using uploader: @Sendable (Item) async throws -> Bool) async throws -> DrainResult {
        guard !pending.isEmpty else { return DrainResult(uploaded: 0, remaining: 0) }

        // Snapshot the drain order up front so a re-enqueue racing this drain
        // (serialized by the actor between awaits) cannot shift what we iterate.
        let toAttempt = pending.values
        var uploadedCount = 0

        do {
            for item in toAttempt {
                let didUpload = try await uploader(item)
                guard didUpload else { continue }
                // Only remove if still the same identity we attempted — a
                // re-enqueue during the await may have replaced this key with a
                // newer total that has not been uploaded yet.
                if pending.matches(item) {
                    pending.remove(item)
                    uploadedCount += 1
                }
            }
        } catch {
            // Preserve whatever survived (in-flight + unattempted items stay
            // queued) before surfacing the failure, so nothing is lost.
            try? persist()
            throw error
        }

        try persist()
        return DrainResult(uploaded: uploadedCount, remaining: pending.count)
    }

    /// Outcome of a ``drain(using:)`` pass.
    public struct DrainResult: Sendable, Equatable {
        /// Items that uploaded successfully and were removed from the queue.
        public let uploaded: Int
        /// Items still queued after the pass (failed uploads, or items enqueued
        /// concurrently). They recover on the next drain.
        public let remaining: Int
    }

    // MARK: - Persistence

    /// Rewrite the whole pending set to `fileURL` as JSON Lines, atomically.
    ///
    /// One ``LeaderboardRecord`` per line, in drain order, with sorted keys for a
    /// deterministic, diff-friendly file. An empty queue writes a zero-byte file,
    /// which ``load(from:readData:)`` reads back as "no pending items".
    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var lines: [String] = []
        lines.reserveCapacity(pending.count)
        for item in pending.values {
            let data = try encoder.encode(item)
            // Encoded scalar rows never contain a newline, so each object is
            // exactly one JSONL line. `JSONEncoder` always emits valid UTF-8, so
            // the failable decode never yields `nil` here.
            lines.append(String(bytes: data, encoding: .utf8) ?? "")
        }

        let contents = lines.joined(separator: "\n")
        try writeData(Data(contents.utf8), fileURL)
    }

    /// Read and decode the persisted pending items from `fileURL`.
    ///
    /// A missing file (read returns `nil`) or empty file yields an empty queue.
    /// Lines that fail to decode (a partially written tail line, a corrupted row)
    /// are skipped so one bad line cannot strand the rest. Later lines win on a
    /// duplicate `(date, provider)`, matching enqueue's newest-wins semantics.
    private static func load(
        from fileURL: URL,
        readData: @Sendable (URL) throws -> Data?
    ) -> OrderedItems {
        guard let data = try? readData(fileURL),
              let contents = String(bytes: data, encoding: .utf8),
              !contents.isEmpty
        else {
            return OrderedItems()
        }

        let decoder = JSONDecoder()
        var items = OrderedItems()
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let item = try? decoder.decode(Item.self, from: Data(trimmed.utf8)) else { continue }
            items.upsert(item)
        }
        return items
    }
}

/// An insertion-ordered, `(date, provider)`-keyed collection of pending items.
///
/// Keying on ``LeaderboardRecord/id`` ("date|provider") enforces the dedup
/// invariant — at most one item per `(date, provider)` — while a parallel order
/// array preserves enqueue order for oldest-first draining. An upsert of an
/// existing key updates the value in place without changing its position.
private struct OrderedItems {
    private var byKey: [String: OfflineUploadQueue.Item] = [:]
    private var order: [String] = []

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    /// Items in enqueue order (oldest first).
    var values: [OfflineUploadQueue.Item] { order.compactMap { byKey[$0] } }

    /// Insert `item`, or replace the existing item with the same `(date,
    /// provider)` key in place (position unchanged).
    mutating func upsert(_ item: OfflineUploadQueue.Item) {
        if byKey[item.id] == nil { order.append(item.id) }
        byKey[item.id] = item
    }

    /// Remove the item sharing `item`'s `(date, provider)` key, if present.
    mutating func remove(_ item: OfflineUploadQueue.Item) {
        guard byKey.removeValue(forKey: item.id) != nil else { return }
        order.removeAll { $0 == item.id }
    }

    /// True when the currently queued item for `item`'s key is value-equal to
    /// `item` (i.e. not replaced by a newer total since it was snapshotted).
    func matches(_ item: OfflineUploadQueue.Item) -> Bool {
        byKey[item.id] == item
    }
}
