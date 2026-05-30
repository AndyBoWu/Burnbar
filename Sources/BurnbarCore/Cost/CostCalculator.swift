import Foundation

// =============================================================================
// CostCalculator (1.4.2) — turns a UsageRecord's token counts into a dollar
// figure by applying per-model rates from `PricingTable` (1.4.1).
//
// This is the only place rates are applied to tokens. It consumes the unified
// `UsageRecord` (1.2.3) and feeds every priced number the UI shows (Epic 1.5)
// and the time-window aggregator (1.4.3).
//
// Contract (CLAUDE.md "Architecture" + data-sources.md "Codex token granularity
// caveat"):
//   - cost = Σ (tokensₖ × rateₖ) / 1,000,000, where rates are per-MTok and
//     `nil` token fields count as 0 — so Codex records (only `inputTokens`
//     populated) price correctly without crashing.
//   - Unknown model → log a warning, treat as $0, and surface an
//     `isUnknownModel` flag the UI renders as "Unknown model"; never silently
//     drop the record.
// =============================================================================

/// Applies `PricingTable` rates to a `UsageRecord`'s token breakdown, producing
/// a USD cost. Stateless and `Sendable`, so it can be shared freely across the
/// app's concurrency domains.
///
/// Rates in `PricingTable` are `Decimal` USD-per-MTok; costing is done in
/// `Decimal` (exact base-10 arithmetic) to match the `claude-usage-tracker`
/// (Python) reference figures without binary-floating-point drift, then the
/// final dollar amount is exposed as the `Double` that `UsageRecord.costUSD`
/// and the aggregator expect.
public struct CostCalculator: Sendable {
    /// Source of per-model rates. Defaults to the static `PricingTable` lookup;
    /// injectable so tests can pin a known rate set independent of the live
    /// table (and so the unknown-model path can be exercised deterministically).
    public typealias PricingLookup = @Sendable (_ model: String) -> ModelPricing?

    private let pricingLookup: PricingLookup

    /// - Parameter pricingLookup: resolves a raw model id to its `ModelPricing`,
    ///   or `nil` for an unknown model. Defaults to `PricingTable.pricing(for:)`.
    public init(pricingLookup: @escaping PricingLookup = PricingTable.pricing(for:)) {
        self.pricingLookup = pricingLookup
    }

    /// Result of costing a single record: the dollar figure plus whether the
    /// model was unknown to the pricing table.
    ///
    /// `cost` is `0` when `isUnknownModel` is `true`, so callers that only care
    /// about money can ignore the flag; the UI reads `isUnknownModel` to render
    /// "Unknown model" instead of a misleading `$0.00`.
    public struct CostResult: Sendable, Equatable {
        /// USD cost for the record. `0` for an unknown model (never guessed).
        public let cost: Decimal
        /// `true` when the record's model is absent from the pricing table.
        public let isUnknownModel: Bool

        public init(cost: Decimal, isUnknownModel: Bool) {
            self.cost = cost
            self.isUnknownModel = isUnknownModel
        }
    }

    // MARK: - Single record

    /// Cost a single record, returning the dollar figure plus the unknown-model
    /// flag. On an unknown model this logs one warning to stderr, returns `$0`,
    /// and sets `isUnknownModel = true` — the record is never dropped.
    public func result(for record: UsageRecord) -> CostResult {
        guard let pricing = pricingLookup(record.model) else {
            warnUnknownModel(record.model)
            return CostResult(cost: 0, isUnknownModel: true)
        }
        return CostResult(cost: cost(tokens: record, pricing: pricing), isUnknownModel: false)
    }

    /// Cost a single record as a plain `Decimal`. Unknown models cost `$0`
    /// (and still log a warning via `result(for:)`); callers needing to
    /// distinguish "$0 because unknown" from "$0 because no tokens" should use
    /// ``result(for:)`` instead.
    public func cost(for record: UsageRecord) -> Decimal {
        result(for: record).cost
    }

    /// Return a copy of `record` with `costUSD` populated from the pricing
    /// table. For an unknown model `costUSD` is set to `0` (a concrete value,
    /// not `nil`) so downstream sums stay correct; the UI distinguishes
    /// unknown-model records via ``result(for:)``'s flag, not via a `nil` cost.
    public func priced(_ record: UsageRecord) -> UsageRecord {
        var copy = record
        copy.costUSD = doubleValue(of: cost(for: record))
        return copy
    }

    // MARK: - Batch

    /// Cost every record, returning copies with `costUSD` populated. Order is
    /// preserved. Convenience for the aggregation pipeline (1.4.3), which needs
    /// priced records before bucketing.
    public func priced(_ records: [UsageRecord]) -> [UsageRecord] {
        records.map(priced)
    }

    /// Total USD cost across `records`, as a `Decimal`. Unknown models
    /// contribute `$0` (and each logs a warning). Used where only the grand
    /// total matters and per-record copies aren't needed.
    public func cost(for records: [UsageRecord]) -> Decimal {
        records.reduce(Decimal(0)) { $0 + cost(for: $1) }
    }

    // MARK: - Core arithmetic

    /// cost = Σ (tokensₖ × rateₖ) / 1,000,000, with `nil` token fields treated
    /// as `0`. Done in `Decimal` for exact base-10 results matching the Python
    /// reference. Dividing once at the end (rather than per category) keeps the
    /// arithmetic associative and avoids intermediate rounding.
    private func cost(tokens record: UsageRecord, pricing: ModelPricing) -> Decimal {
        let input = Decimal(record.inputTokens) * pricing.inputPerMTok
        let output = Decimal(record.outputTokens ?? 0) * pricing.outputPerMTok
        let cacheRead = Decimal(record.cacheReadTokens ?? 0) * pricing.cacheReadPerMTok
        let cacheCreate = Decimal(record.cacheCreationTokens ?? 0) * pricing.cacheCreatePerMTok
        return (input + output + cacheRead + cacheCreate) / Self.tokensPerMTok
    }

    /// `1_000_000` as a `Decimal`, the per-MTok denominator.
    private static let tokensPerMTok = Decimal(1_000_000)

    /// Convert a `Decimal` cost to the `Double` stored in `UsageRecord.costUSD`.
    private func doubleValue(of decimal: Decimal) -> Double {
        NSDecimalNumber(decimal: decimal).doubleValue
    }

    /// One-line stderr warning, matching the house style used by the readers
    /// (`StatsCacheReader` / `JSONLDeltaScanner`).
    private func warnUnknownModel(_ model: String) {
        FileHandle.standardError.write(
            Data("[CostCalculator] warning: unknown model \"\(model)\"; costed as $0 (surfaced as \"Unknown model\").\n".utf8)
        )
    }
}
