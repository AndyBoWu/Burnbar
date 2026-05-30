import Foundation

/// Maps Codex's daily per-model token totals into the provider-agnostic
/// ``UsageRecord`` currency consumed by the cost engine (Epic 1.4), the UI
/// (Epic 1.5), and cross-device aggregation (M2).
///
/// This is the Codex counterpart to ``ClaudeUsageProvider`` and the capstone of
/// the Codex parser (Epic 1.3, sub-ticket 1.3.3). It performs **no SQL of its
/// own** — it consumes the already-aggregated rows from ``CodexThreadsReader``
/// (1.3.2) and translates each `(day, model, tokens)` bucket into a
/// `UsageRecord` with `provider == .codex`.
///
/// ## Token-granularity caveat (the Codex asymmetry)
///
/// Codex's `threads` table stores **only a single `tokens_used` integer per
/// thread** — there is no input / output / cache-read / cache-creation
/// breakdown (see docs/data-sources.md "Codex token granularity caveat" and the
/// type-level note on ``CodexDailyModelTokens``). So each bucket's opaque total
/// is mapped to ``UsageRecord/inputTokens`` and the remaining token fields are
/// left **`nil`** — never fabricated zeros:
///
/// - ``UsageRecord/inputTokens``  = `row.tokens` (the summed `tokens_used`)
/// - ``UsageRecord/outputTokens`` = `nil`
/// - ``UsageRecord/cacheReadTokens`` = `nil`
/// - ``UsageRecord/cacheCreationTokens`` = `nil`
///
/// This mirrors how ``ClaudeUsageProvider`` maps its single-aggregate historical
/// days, and is documented on ``UsageRecord`` itself so consumers render the
/// asymmetry (Codex tile = total only; Claude tile = stacked breakdown) rather
/// than papering over it. ``UsageRecord/totalTokens`` treats the `nil` fields as
/// absent, so a Codex record's total still equals its `inputTokens` — which is
/// exactly the bucket's `tokens` — satisfying the DoD "total matches threads
/// sum".
///
/// ## Day key
///
/// `row.day` already arrives as `YYYY-MM-DD` from the reader's
/// `DATE(created_at_ms/1000,'unixepoch')` projection (UTC), the canonical
/// ``UsageRecord/day`` format. It is used **verbatim** — no re-parse or
/// re-format — matching how ``ClaudeUsageProvider`` reuses its source's
/// pre-bucketed date strings and avoiding any timezone drift from a needless
/// `Date` round-trip.
///
/// ## Cost
///
/// Every emitted record leaves ``UsageRecord/costUSD`` `nil`; pricing is applied
/// downstream by `CostCalculator` against `PricingTable` (Epic 1.4), never here.
///
/// ## Privacy
///
/// Only `model`, `day`, and the token total cross into `UsageRecord`. The
/// content/path columns (`title`, `first_user_message`, `preview`, `cwd`,
/// `git_*`, `rollout_path`) are never read by the underlying query (1.3.2), so
/// they cannot appear here or leak into the M3 upload payload. See the privacy
/// thesis in CLAUDE.md and docs/data-sources.md.
public struct CodexUsageProvider: Sendable {
    /// The reader that runs Burnbar's single Codex aggregation query (1.3.2).
    private let reader: CodexThreadsReader

    /// Creates a Codex usage provider over the given threads reader.
    ///
    /// - Parameter reader: a ``CodexThreadsReader``. Defaults to one targeting
    ///   `~/.codex/state_5.sqlite`; inject a fixture-backed reader in tests.
    public init(reader: CodexThreadsReader = CodexThreadsReader()) {
        self.reader = reader
    }

    /// The resolved path to the Codex database being read. Convenience
    /// pass-through for diagnostics/UI; does not open the file.
    public var databasePath: String { reader.databasePath }

    /// Whether the underlying Codex database file currently exists. Cheap
    /// pre-check so callers can distinguish "Codex never ran here" from a real
    /// read error.
    public var databaseExists: Bool { reader.databaseExists }

    /// Produces the Codex usage timeline: one ``UsageRecord`` per
    /// `(day, model)` bucket, all with `provider == .codex` and
    /// `costUSD == nil`.
    ///
    /// Each bucket's `tokens` total maps to ``UsageRecord/inputTokens`` with the
    /// other token fields `nil` (the Codex granularity caveat above), so the sum
    /// of returned ``UsageRecord/inputTokens`` equals the sum of the reader's
    /// `tokens` — the DoD.
    ///
    /// An empty/absent database, an empty `threads` table, or rows with only
    /// `NULL` `created_at_ms` all yield an **empty array** (the reader's
    /// contract), not an error.
    ///
    /// Records are returned sorted by `(day, model)` for stable, testable output,
    /// matching ``ClaudeUsageProvider/usageRecords()`` so a merged cross-provider
    /// stream is deterministic.
    ///
    /// - Returns: merged `[UsageRecord]` with `provider == .codex`.
    /// - Throws: ``CodexThreadsReaderError`` if the read-only SQLite layer fails
    ///   (missing file, open/prepare/step error) or a result row is malformed.
    public func usageRecords() throws -> [UsageRecord] {
        let rows = try reader.dailyModelTokens()

        var records = rows.map { row in
            UsageRecord(
                provider: .codex,
                model: row.model,
                day: row.day,
                // Codex exposes a single opaque total with no breakdown: map it
                // to inputTokens and leave the rest nil (never fabricate zeros).
                inputTokens: row.tokens,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                costUSD: nil
            )
        }

        // Stable ordering for deterministic consumers/tests. The reader already
        // yields one row per (day, model), so (day, model) is a total order.
        records.sort { lhs, rhs in
            lhs.day == rhs.day ? lhs.model < rhs.model : lhs.day < rhs.day
        }
        return records
    }
}
