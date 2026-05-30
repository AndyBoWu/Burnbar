import Foundation

/// The most reduced, non-identifying form of usage that is allowed to leave this
/// machine for the M3 global leaderboard: one row per `(date, provider)`.
///
/// This DTO is the hard privacy allowlist for the upload payload (CLAUDE.md M3,
/// docs/data-sources.md "never upload" list). Its entire `Codable` surface is
/// **exactly** four scalar fields — `date`, `provider`, `tokens`, `cost_usd`.
/// It deliberately carries **no** `model` / raw model name, **no** `machine_id`
/// or per-machine breakdown, and **no** `cwd` / project dir / `git_*` / prompt /
/// title / preview. Restricting the type to these keys means a field added later
/// to `UsageRecord` (or `RollupLine`) cannot silently leak into the leaderboard:
/// it simply has nowhere to go.
///
/// `tokens` is a single grand total (Int) — the sum of every `UsageRecord`'s
/// `totalTokens` in the bucket, which already collapses the Claude
/// input/output/cache breakdown and the Codex single-integer total into one
/// number. The model-level asymmetry is intentionally erased here: the
/// leaderboard ranks by `(date, provider)` only.
public struct LeaderboardRecord: Codable, Sendable, Equatable, Identifiable {
    /// Local calendar day, `YYYY-MM-DD` (verbatim from `UsageRecord.day`).
    public let date: String
    /// Source provider (`claude` / `codex`). The only identity dimension besides
    /// the day — no model, no machine.
    public let provider: Provider
    /// Grand total tokens for this `(date, provider)` across all machines and all
    /// models, summed from each record's `totalTokens`.
    public let tokens: Int
    /// Summed USD cost for this `(date, provider)`. Records with no cost (`nil`,
    /// e.g. uncosted or unknown-model) contribute `0`.
    public let costUSD: Double

    public init(date: String, provider: Provider, tokens: Int, costUSD: Double) {
        self.date = date
        self.provider = provider
        self.tokens = tokens
        self.costUSD = costUSD
    }

    /// Stable identity for SwiftUI lists / dedup: one row per `(date, provider)`.
    public var id: String { "\(date)|\(provider.rawValue)" }

    /// The wire field names. `costUSD` serializes as the validator-mandated
    /// `cost_usd`; the rest map 1:1. Listing every key explicitly (rather than
    /// relying on synthesized keys) keeps the upload payload's JSON shape pinned
    /// to the privacy schema and obvious at the call site.
    private enum CodingKeys: String, CodingKey {
        case date
        case provider
        case tokens
        case costUSD = "cost_usd"
    }
}

/// Stage one of the M3 upload pipeline (3.3.1): collapse the cross-machine,
/// per-model reconciled usage into leaderboard-safe daily rollups — one
/// `LeaderboardRecord` per `(date, provider)` carrying only `tokens` and
/// `cost_usd`.
///
/// This is a **pure function** over its input — no I/O, no network, no clock, no
/// global state. The caller supplies the already-reconciled usage (the M2
/// `Reconciler` output, summed across every machine); this type only folds it
/// down to the minimal shape and strips every identifying field. Keeping it pure
/// makes the Definition of Done — output totals equal the sum of the input, and
/// the output carries no `machine_id` / `model` / path — trivially testable, and
/// the type `Sendable`/stateless.
///
/// ## What gets stripped
/// The input `UsageRecord`s still carry `model` and the input/output/cache token
/// breakdown; the M2 `byMachine` map still keys by `machine_id`. Aggregation here
/// erases all of it: records are grouped by `(date, provider)` only, every
/// model's tokens fold into one `tokens` total via `totalTokens`, and the
/// `machine_id` dimension never enters because the input is already the combined
/// (cross-machine) view. The result type has no field that could carry any of it.
public struct LeaderboardAggregator: Sendable {
    public init() {}

    /// Aggregate the reconciler's cross-machine combined view into
    /// leaderboard-safe `(date, provider)` rollups.
    ///
    /// Reads `reconciled.combined` — the one-`UsageRecord`-per-`(day, provider,
    /// model)` view summed across **all** machines (Epic 2.3) — and never touches
    /// `reconciled.byMachine`, so no `machine_id` can leak.
    ///
    /// - Parameter reconciled: The M2 `Reconciler` output, already summed across
    ///   every machine.
    /// - Returns: One `LeaderboardRecord` per `(date, provider)`; see
    ///   ``aggregate(_:)`` for ordering and summation semantics.
    public func aggregate(_ reconciled: ReconciledUsage) -> [LeaderboardRecord] {
        aggregate(reconciled.combined)
    }

    /// Aggregate a flat list of (already cross-machine reconciled) `UsageRecord`s
    /// into leaderboard-safe `(date, provider)` rollups.
    ///
    /// For each `(date, provider)` bucket:
    /// - `tokens` is the sum of every record's `totalTokens` (which folds Claude's
    ///   input/output/cache categories and Codex's single `inputTokens` total into
    ///   one number — `nil` categories count as absent, never a fabricated `0`).
    /// - `cost_usd` is the sum of every record's `costUSD`, treating `nil`
    ///   (uncosted / unknown model) as `0`.
    ///
    /// Output is sorted by day descending, then provider, so the payload is
    /// deterministic across runs regardless of input order. `model`, `machine_id`,
    /// and every per-machine / per-model detail are dropped — the result type
    /// cannot represent them.
    ///
    /// - Parameter records: Reconciled usage (one record per `(day, provider,
    ///   model)` across all machines, but a flat unreconciled list also folds
    ///   correctly since grouping is by `(date, provider)`).
    /// - Returns: One `LeaderboardRecord` per distinct `(date, provider)`. Empty
    ///   input yields an empty array.
    public func aggregate(_ records: [UsageRecord]) -> [LeaderboardRecord] {
        var buckets: [Key: Accumulator] = [:]

        for record in records {
            let key = Key(date: record.day, provider: record.provider)
            buckets[key, default: Accumulator()].add(record)
        }

        return buckets
            .map { key, accumulator in
                LeaderboardRecord(
                    date: key.date,
                    provider: key.provider,
                    tokens: accumulator.tokens,
                    costUSD: accumulator.costUSD
                )
            }
            .sorted(by: Self.ordered)
    }

    // MARK: - Grouping

    /// The only identity a leaderboard row is summed under — deliberately *not*
    /// keyed by `model` or `machine_id`, which is what collapses every model and
    /// every machine into one total.
    private struct Key: Hashable {
        let date: String
        let provider: Provider
    }

    /// Running totals for one `(date, provider)` bucket. `tokens` always sums (every
    /// record has a `totalTokens`); `costUSD` treats `nil` as `0`.
    private struct Accumulator {
        var tokens = 0
        var costUSD = 0.0

        mutating func add(_ record: UsageRecord) {
            tokens += record.totalTokens
            costUSD += record.costUSD ?? 0
        }
    }

    // MARK: - Ordering

    /// Deterministic payload ordering: newest day first, then provider. Zero-padded
    /// `YYYY-MM-DD` days compare lexicographically in chronological order.
    private static func ordered(_ lhs: LeaderboardRecord, _ rhs: LeaderboardRecord) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.provider.rawValue < rhs.provider.rawValue
    }
}
