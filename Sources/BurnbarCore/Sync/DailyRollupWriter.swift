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
/// Scope boundary: this is the plain write. Atomic replacement is 2.2.3 and
/// scheduling is 2.2.4 — this writer just resolves the URL and writes the bytes.
/// The destination directory is injected (the caller passes the URL resolved by
/// `ICloudContainer`, 2.2.1), so tests point it at a temp directory.
///
/// `Sendable` and stateless: holds only an immutable directory URL and a closure
/// for the write side effect, so it is safe to call from any concurrency domain.
public struct DailyRollupWriter: Sendable {
    /// The resolved iCloud `Burnbar/` directory the rollup file is written into.
    private let directory: URL
    /// Injected write primitive (`Data` → file URL). Defaults to an atomic-free
    /// overwrite; 2.2.3 swaps in the atomic variant.
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(
        directory: URL,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url)
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
