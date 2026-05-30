import Foundation

/// The reconciler's unified output: every machine's usage collapsed into a single
/// daily view, plus the untouched per-machine breakdown for drilldown.
///
/// `combined` holds one `UsageRecord` per `(day, provider, model)` key, summed
/// across **all** machines — the Combined-view UI (Epic 2.4) renders this as the
/// grand total. `byMachine` is the input map passed straight through, so the
/// per-machine drilldown panel can split that grand total back into each machine's
/// contribution.
///
/// The Definition of Done is an invariant on these two: the combined total equals
/// the sum of every machine's totals (see `Reconciler.merge`). `Sendable` so the
/// result can cross actor/concurrency boundaries to the UI layer.
public struct ReconciledUsage: Sendable, Equatable {
    /// One summed `UsageRecord` per `(day, provider, model)` key across all
    /// machines, in deterministic order (day descending, then provider, then
    /// model) for stable UI rendering.
    public let combined: [UsageRecord]

    /// The per-machine input, preserved verbatim. Keyed by `machine_id`; each
    /// value is that machine's records exactly as supplied — no summing, sorting,
    /// or coercion — so Epic 2.4's drilldown sees the unmodified split.
    public let byMachine: [String: [UsageRecord]]

    public init(combined: [UsageRecord], byMachine: [String: [UsageRecord]]) {
        self.combined = combined
        self.byMachine = byMachine
    }
}

/// Stage two of the reconciler (2.3.3): merge every machine's `UsageRecord`s
/// (supplied by `MultiMachineReader.readAll()`, 2.3.1) into one unified daily view
/// while retaining the per-machine breakdown for drilldown.
///
/// This is a **pure function** over its injected input — no I/O, no clock, no
/// global state. The caller does the reading; `merge` only folds. That keeps the
/// DoD invariant (combined total == sum of per-machine totals) trivially testable
/// and the type `Sendable`/stateless.
///
/// ## Token asymmetry
/// `inputTokens` is always present, so it always sums. The optional categories
/// (`outputTokens`, `cacheReadTokens`, `cacheCreationTokens`) and `costUSD` follow
/// a **sum-of-present** rule: a value is contributed only when a machine actually
/// reported it. The field stays `nil` in the combined record exactly when **no**
/// contributing machine supplied it — Codex's `nil` categories are never coerced
/// to `0` (see docs/data-sources.md). When at least one machine reports a value,
/// the sum reflects only the reporting machines.
public struct Reconciler: Sendable {
    public init() {}

    /// Union the per-machine records over the composite key `(day, provider,
    /// model)`, summing token fields and cost, and return both the combined view
    /// and the untouched `byMachine` input.
    ///
    /// - Parameter byMachine: `[machine_id: [UsageRecord]]`, as produced by
    ///   `MultiMachineReader.readAll()`. Passed through unchanged into the result.
    /// - Returns: A `ReconciledUsage` whose `combined` total equals the sum of all
    ///   per-machine totals (the DoD invariant).
    public func merge(_ byMachine: [String: [UsageRecord]]) -> ReconciledUsage {
        // Accumulate into running sums keyed by (day, provider, model). Insertion
        // order is irrelevant — the result is sorted deterministically below.
        var accumulators: [GroupKey: Accumulator] = [:]

        // Iterate machines in a stable order so the fold is deterministic, even
        // though the final sort makes ordering independent of this anyway.
        for machineID in byMachine.keys.sorted() {
            for record in byMachine[machineID] ?? [] {
                let key = GroupKey(record)
                accumulators[key, default: Accumulator()].add(record)
            }
        }

        let combined = accumulators
            .map { $0.value.makeRecord(key: $0.key) }
            .sorted(by: Self.ordered)

        return ReconciledUsage(combined: combined, byMachine: byMachine)
    }

    // MARK: - Grouping

    /// The composite identity a record is summed under: one combined `UsageRecord`
    /// per distinct `(day, provider, model)`.
    private struct GroupKey: Hashable {
        let day: String
        let provider: Provider
        let model: String

        init(_ record: UsageRecord) {
            day = record.day
            provider = record.provider
            model = record.model
        }
    }

    /// Running totals for one `GroupKey`. Optional categories track "did any
    /// machine report this?" via `nil` so absence never becomes a fabricated `0`.
    private struct Accumulator {
        var inputTokens = 0
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var costUSD: Double?

        mutating func add(_ record: UsageRecord) {
            inputTokens += record.inputTokens
            outputTokens = Self.sum(outputTokens, record.outputTokens)
            cacheReadTokens = Self.sum(cacheReadTokens, record.cacheReadTokens)
            cacheCreationTokens = Self.sum(cacheCreationTokens, record.cacheCreationTokens)
            costUSD = Self.sum(costUSD, record.costUSD)
        }

        func makeRecord(key: GroupKey) -> UsageRecord {
            UsageRecord(
                provider: key.provider,
                model: key.model,
                day: key.day,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                costUSD: costUSD
            )
        }

        /// Sum-of-present: `nil + nil = nil`, `nil + x = x`, `x + y = x + y`. The
        /// running total stays `nil` until some machine contributes a value, so an
        /// all-`nil` category (every contributor was Codex) survives as `nil`.
        private static func sum(_ running: Int?, _ next: Int?) -> Int? {
            guard let next else { return running }
            return (running ?? 0) + next
        }

        private static func sum(_ running: Double?, _ next: Double?) -> Double? {
            guard let next else { return running }
            return (running ?? 0) + next
        }
    }

    // MARK: - Ordering

    /// Deterministic combined ordering: newest day first, then provider, then
    /// model — both `YYYY-MM-DD` days and model strings compare lexicographically,
    /// and zero-padded days make lexicographic order match chronological order.
    private static func ordered(_ lhs: UsageRecord, _ rhs: UsageRecord) -> Bool {
        if lhs.day != rhs.day { return lhs.day > rhs.day }
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        return lhs.model < rhs.model
    }
}
