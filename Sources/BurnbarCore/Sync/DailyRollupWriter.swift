import Foundation

/// One serialized line in a machine's `{machine_id}.jsonl` rollup file.
///
/// This is the **only** shape that is allowed to leave `UsageRecord` and land in
/// the shared iCloud directory, so its fields are a hard privacy allowlist:
/// `date`, `provider`, `model`, the four token categories, and `costUSD`. It
/// carries **no** `cwd`, project directory name, `git_*`, `title`,
/// `first_user_message`, `preview`, or `message.content` — see CLAUDE.md's
/// privacy thesis and docs/data-sources.md's "never read"/⚠ lists. Restricting
/// the `Codable` surface to these keys means a future field added to
/// `UsageRecord` cannot silently leak into the rollup.
///
/// The model name *is* retained here: this local iCloud rollup is per-machine and
/// never uploaded as-is. The M3 leaderboard step strips `model` (and reduces to
/// `{date, provider, tokens, cost_usd}`) separately, so keeping it here costs no
/// privacy and lets the Reconciler (Epic 2.3) preserve per-model detail.
///
/// Token/cost fields stay optional to honour the Claude/Codex asymmetry: Codex
/// reports only a single total (mapped to `inputTokens`), so `outputTokens`,
/// both cache fields, and (pre-costing) `costUSD` encode as absent rather than a
/// fabricated `0`.
public struct RollupLine: Codable, Sendable, Equatable {
    /// Local calendar day, `YYYY-MM-DD` (verbatim from `UsageRecord.day`).
    public let date: String
    /// Source provider (`claude` / `codex`).
    public let provider: Provider
    /// Raw model identifier, e.g. `claude-opus-4-7` or `gpt-5`.
    public let model: String
    /// Summed input (prompt) tokens for this (date, provider, model) bucket.
    public let inputTokens: Int
    /// Summed output tokens, or `nil` when the provider never reports them (Codex).
    public let outputTokens: Int?
    /// Summed cache-read tokens, or `nil` when unavailable (Codex).
    public let cacheReadTokens: Int?
    /// Summed cache-creation tokens, or `nil` when unavailable (Codex).
    public let cacheCreationTokens: Int?
    /// Summed USD cost, or `nil` when uncosted / model unknown to pricing.
    public let costUSD: Double?

    public init(
        date: String,
        provider: Provider,
        model: String,
        inputTokens: Int,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        costUSD: Double?
    ) {
        self.date = date
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }
}

/// Serializes this machine's already-priced `[UsageRecord]` into its own
/// `{machine_id}.jsonl` file inside the shared iCloud `Burnbar/` directory.
///
/// Each machine owns exactly one file, so the file is rewritten wholesale on
/// every run (it is the single source of truth for this Mac) and the Reconciler
/// (Epic 2.3) can union every machine's file with no conflict resolution.
///
/// The output is JSON Lines: one `RollupLine` JSON object per line, with exactly
/// one line per distinct `(date, provider, model)` bucket. Records sharing a
/// bucket are summed; a token category stays `nil` only when **every** record in
/// the bucket left it `nil` (preserving the Codex asymmetry), and `costUSD` stays
/// `nil` only when every record in the bucket was uncosted.
///
/// **Atomicity (2.2.3):** the default write primitive is durable and atomic —
/// it writes the full bytes to a sibling `{machine_id}.tmp`, `fsync`s the file
/// descriptor so the bytes hit disk, then `rename(2)`s the temp over the final
/// `.jsonl` in the same directory (an atomic operation on one volume). A reader
/// — including iCloud Drive, which can begin syncing the instant a file changes,
/// and the cross-machine Reconciler (Epic 2.3) — therefore only ever observes a
/// complete file, never a half-written one. Killing the app mid-write leaves the
/// prior `.jsonl` intact (the rename never ran) and at most a stray `.tmp`, which
/// any failure path also deletes. The destination directory is injected (the
/// caller passes the URL resolved by `ICloudContainer`, 2.2.1), so tests point it
/// at a temp directory.
///
/// `Sendable` and stateless: holds only an immutable directory URL and a closure
/// for the write side effect, so it is safe to call from any concurrency domain.
public struct DailyRollupWriter: Sendable {
    /// The resolved iCloud `Burnbar/` directory the rollup file is written into.
    private let directory: URL
    /// Injected write primitive (`Data` → file URL). Defaults to the atomic
    /// tmp → fsync → rename variant (``atomicWrite(_:to:)``); injectable so tests
    /// can capture the bytes/URL without touching disk.
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(
        directory: URL,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try DailyRollupWriter.atomicWrite(data, to: url)
        }
    ) {
        self.directory = directory
        self.writeData = writeData
    }

    /// The file URL this machine's rollup is written to: `<directory>/{machineID}.jsonl`.
    public func fileURL(machineID: String) -> URL {
        directory.appendingPathComponent("\(machineID).jsonl", isDirectory: false)
    }

    /// Group, serialize, and write `records` to `{machineID}.jsonl`.
    ///
    /// Overwrites any existing file for this machine. Empty `records` writes an
    /// empty file (zero bytes), which the Reconciler reads as "no usage from this
    /// machine" rather than a missing/stale file.
    ///
    /// - Parameters:
    ///   - records: This machine's priced usage. Re-bucketed by
    ///     `(date, provider, model)` here, so the caller need not pre-group.
    ///   - machineID: The 16-char machine id from `MachineIdentity.current()`.
    /// - Throws: Any error from JSON encoding or the injected write primitive.
    public func write(records: [UsageRecord], machineID: String) throws {
        let lines = Self.rollupLines(from: records)

        let encoder = JSONEncoder()
        // Stable key order keeps the file diff-friendly and tests deterministic.
        encoder.outputFormatting = [.sortedKeys]

        var serialized: [String] = []
        serialized.reserveCapacity(lines.count)
        for line in lines {
            let data = try encoder.encode(line)
            // JSONEncoder always emits valid UTF-8, and never a newline for these
            // scalar fields, so each object occupies exactly one JSONL line.
            serialized.append(String(bytes: data, encoding: .utf8) ?? "")
        }

        let contents = serialized.joined(separator: "\n")
        try writeData(Data(contents.utf8), fileURL(machineID: machineID))
    }

    /// Failures from the atomic write primitive (``atomicWrite(_:to:)``).
    ///
    /// Every case is thrown only *after* the partial `.tmp` has been deleted, so a
    /// throw never leaves a stray temp file behind. The thrown error wraps the
    /// underlying POSIX `errno` (where applicable) for triage.
    public enum AtomicWriteError: Error, Equatable, Sendable, CustomStringConvertible {
        /// `fsync` on the temp file's descriptor failed; the bytes are not proven
        /// durable, so the rename is skipped. Carries the POSIX `errno`.
        case syncFailed(errno: Int32)
        /// `rename(2)` of `.tmp` → `.jsonl` failed; the previous `.jsonl` (if any)
        /// is therefore untouched. Carries the POSIX `errno`.
        case renameFailed(errno: Int32)

        public var description: String {
            switch self {
            case let .syncFailed(errno):
                return "Atomic write failed to fsync temp file (errno \(errno): \(Self.message(errno)))."
            case let .renameFailed(errno):
                return "Atomic write failed to rename temp file into place (errno \(errno): \(Self.message(errno)))."
            }
        }

        private static func message(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }

    /// Durably and atomically write `data` to `url`.
    ///
    /// Steps: write the full bytes to a sibling `<url-basename>.tmp` in the **same
    /// directory** (so the rename stays on one volume and is therefore atomic),
    /// `fsync` the file descriptor so the bytes are flushed to stable storage,
    /// then `rename(2)` the temp over `url` — replacing any existing file in a
    /// single indivisible step.
    ///
    /// Because the rename is the only operation that publishes the new contents, a
    /// crash (or app kill) at any earlier point leaves the prior file at `url`
    /// fully intact; a reader never sees a torn write. On **any** failure the
    /// partial `.tmp` is removed before the error is rethrown, so no stray temp
    /// file is ever left behind.
    ///
    /// - Parameters:
    ///   - data: The complete file contents to publish.
    ///   - url: The final destination (e.g. `{machine_id}.jsonl`).
    /// - Throws: ``AtomicWriteError`` for fsync/rename failures, or any error from
    ///   writing the temp file (e.g. the directory not existing).
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        // Sibling temp in the *same* directory: `<final-without-ext>.tmp`. Keeping
        // it on the same volume is what makes the rename atomic. Deleting any
        // existing extension means `foo.jsonl` → `foo.tmp` (matching the ticket's
        // `{machine_id}.tmp`), not `foo.jsonl.tmp`.
        let tempURL = url.deletingPathExtension().appendingPathExtension("tmp")

        // 1. Write the full bytes to the temp file. `.atomic` here is belt-and-
        //    suspenders for the temp itself; the cross-file atomicity comes from
        //    the rename below.
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // 2. fsync the temp's descriptor so the bytes are on stable storage before
        //    we publish them — otherwise a power loss after the rename could leave
        //    a present-but-empty file. Using the raw fd gives us the exact POSIX
        //    `errno` on failure.
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            if fsync(handle.fileDescriptor) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: tempURL)
                throw AtomicWriteError.syncFailed(errno: code)
            }
        } catch let error as AtomicWriteError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // 3. Atomically rename temp → final, replacing any existing file. POSIX
        //    `rename(2)` is atomic on the same filesystem and overwrites the
        //    destination in one step.
        let renamed = tempURL.withUnsafeFileSystemRepresentation { tempPath -> Int32 in
            url.withUnsafeFileSystemRepresentation { finalPath in
                guard let tempPath, let finalPath else { return -1 }
                return rename(tempPath, finalPath)
            }
        }
        if renamed != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicWriteError.renameFailed(errno: code)
        }
    }

    /// Collapse `records` into one `RollupLine` per `(date, provider, model)`,
    /// summing token categories and cost. Output is sorted by
    /// `(date, provider, model)` so the file is deterministic across runs.
    ///
    /// A token field (or `costUSD`) is summed treating `nil` as 0, but stays
    /// `nil` in the result when **no** record in the bucket reported it — so a
    /// Codex-only bucket keeps `outputTokens`/cache/cost absent rather than 0.
    static func rollupLines(from records: [UsageRecord]) -> [RollupLine] {
        var buckets: [BucketKey: Bucket] = [:]
        var order: [BucketKey] = []

        for record in records {
            let key = BucketKey(date: record.day, provider: record.provider, model: record.model)
            if buckets[key] == nil {
                buckets[key] = Bucket()
                order.append(key)
            }
            buckets[key]?.add(record)
        }

        return order
            .map { key in buckets[key]!.finalize(key: key) }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.model < rhs.model
            }
    }

    /// Identity of one rollup bucket.
    private struct BucketKey: Hashable {
        let date: String
        let provider: Provider
        let model: String
    }

    /// Mutable accumulator for a single bucket, collapsed into a `RollupLine`.
    /// Each optional category tracks whether *any* record supplied it so an
    /// all-`nil` Codex category stays absent instead of becoming `0`.
    private struct Bucket {
        var inputTokens = 0
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var costUSD: Double?

        mutating func add(_ record: UsageRecord) {
            inputTokens += record.inputTokens
            outputTokens = sum(outputTokens, record.outputTokens)
            cacheReadTokens = sum(cacheReadTokens, record.cacheReadTokens)
            cacheCreationTokens = sum(cacheCreationTokens, record.cacheCreationTokens)
            costUSD = sum(costUSD, record.costUSD)
        }

        func finalize(key: BucketKey) -> RollupLine {
            RollupLine(
                date: key.date,
                provider: key.provider,
                model: key.model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                costUSD: costUSD
            )
        }

        /// `nil` + `nil` → `nil`; otherwise sum, treating a `nil` operand as 0.
        private func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }

        private func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
            guard lhs != nil || rhs != nil else { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
    }
}
