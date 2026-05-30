import Foundation

/// One row of the popover's expandable per-machine breakdown panel (Epic 2.4.3):
/// a single machine's display identity plus its **today** burn, ready for SwiftUI
/// to render directly.
///
/// This is the pure, view-agnostic projection the popover's `MachineBreakdownView`
/// renders. Keeping it — and its assembly in ``MachineBreakdownBuilder`` — in
/// `BurnbarCore` makes the per-machine today-burn maths, the top-model pick, the
/// stale flagging, and the burn-descending sort unit-testable without launching
/// the app.
///
/// It deliberately mirrors the All-Macs popover source: the reconciled
/// `byMachine` map (`[machine_id: [UsageRecord]]`, 2.3.1/2.3.3) that `UsageStore`
/// already loads for the combined total, not the Settings table's `MachineUsage`
/// list. So the panel splits the *same* grand total the badge counts, and the two
/// can never disagree.
///
/// Privacy: a row carries only the opaque `machine_id`, a user/registry label, the
/// today token + cost totals, and a raw model id — never `cwd`, `git_*`, project
/// dir names, or any user content (the privacy thesis). The truncated id for
/// compact display is derived here, not by the view.
public struct MachineBreakdownRow: Sendable, Equatable, Identifiable {
    /// The opaque machine id (the `{machine_id}.jsonl` filename stem) — also the
    /// stable SwiftUI list identity.
    public let id: String

    /// Human-readable name: the user/registry label, falling back to the id itself
    /// when nothing friendlier exists.
    public let label: String

    /// `true` when this row is the Mac the app is currently running on, so the UI
    /// can tag it "This Mac".
    public let isThisMac: Bool

    /// `true` when this machine was flagged stale by ``StaleMachineDetector``
    /// (2.3.4). The UI dims the row and appends "(stale)".
    public let isStale: Bool

    /// Today's total token burn across every provider/model for this machine.
    public let todayTokens: Int

    /// Today's total USD cost for this machine.
    public let todayCostUSD: Double

    /// The raw id of the model this machine burned the most tokens on today, or
    /// `nil` when it has no usage today. Shown verbatim — pricing/labelling is the
    /// view's concern, not this projection's.
    public let topModel: String?

    public init(
        id: String,
        label: String,
        isThisMac: Bool,
        isStale: Bool,
        todayTokens: Int,
        todayCostUSD: Double,
        topModel: String?
    ) {
        self.id = id
        self.label = label
        self.isThisMac = isThisMac
        self.isStale = isStale
        self.todayTokens = todayTokens
        self.todayCostUSD = todayCostUSD
        self.topModel = topModel
    }

    /// The machine id truncated to its first 8 hex chars for compact display
    /// (full ids are 16 chars — see `MachineIdentity`). Privacy-safe: the id is
    /// already a one-way hash, and showing only a prefix keeps the panel tidy.
    public var shortID: String {
        String(id.prefix(8))
    }
}

/// Assembles ``MachineBreakdownRow``s from the reconciled per-machine snapshot the
/// popover already holds in All-Macs mode (Epic 2.4.3).
///
/// Pure over its injected inputs — no I/O, no clock beyond the injected `now`, no
/// global state — so `UsageStore` can build the panel off the main actor (where it
/// already reconciles) and hand a finished, `Sendable` list to the view. The
/// costing/aggregation reuse the same `CostCalculator` + `TimeWindowAggregator` the
/// combined total uses, so each machine's today burn sums to the displayed grand
/// total.
///
/// Sort + DoD: rows come back sorted by today's burn **descending** (stable
/// tiebreak: this Mac first, then label case-insensitively, then id), which reads
/// well for the 1–5 machine range the ticket targets.
public struct MachineBreakdownBuilder: Sendable {
    private let calculator: CostCalculator
    private let aggregator: TimeWindowAggregator

    public init(
        calculator: CostCalculator = CostCalculator(),
        aggregator: TimeWindowAggregator = TimeWindowAggregator()
    ) {
        self.calculator = calculator
        self.aggregator = aggregator
    }

    /// The cross-cutting inputs shared by every row build: identity, label source,
    /// the stale set, and the "today" reference instant. Bundled so the build entry
    /// point stays a single argument.
    public struct Context: Sendable {
        /// This Mac's id, so its row is flagged "This Mac".
        public let thisMachineID: String

        /// `[machine_id: label]` of friendly names (the local Mac's `MachineLabel`
        /// plus every other machine's `MachineRegistry` label). A machine absent
        /// from the map falls back to its raw id.
        public let labels: [String: String]

        /// The `machine_id`s flagged stale by ``StaleMachineDetector`` (2.3.4).
        /// Their rows are dimmed and suffixed "(stale)".
        public let staleIDs: Set<String>

        /// Reference instant for the "today" window (injectable for tests).
        public let now: Date

        public init(
            thisMachineID: String,
            labels: [String: String],
            staleIDs: Set<String> = [],
            now: Date = Date()
        ) {
            self.thisMachineID = thisMachineID
            self.labels = labels
            self.staleIDs = staleIDs
            self.now = now
        }
    }

    /// Build the panel rows from the reconciled `byMachine` map and the shared
    /// ``Context``.
    ///
    /// - Parameters:
    ///   - byMachine: `[machine_id: [UsageRecord]]`, exactly the map
    ///     `ReconciledUsage.byMachine` exposes (the machines summed into the
    ///     combined total the badge counts).
    ///   - context: identity, labels, stale set, and the "today" instant.
    /// - Returns: one row per machine, sorted by today's burn descending.
    public func rows(from byMachine: [String: [UsageRecord]], context: Context) -> [MachineBreakdownRow] {
        byMachine
            .map { row(machineID: $0.key, records: $0.value, context: context) }
            .sorted(by: Self.ordered)
    }

    private func row(machineID: String, records: [UsageRecord], context: Context) -> MachineBreakdownRow {
        let priced = calculator.priced(records)
        let today = aggregator.aggregate(priced, window: .today, now: context.now)

        return MachineBreakdownRow(
            id: machineID,
            label: context.labels[machineID] ?? machineID,
            isThisMac: machineID == context.thisMachineID,
            isStale: context.staleIDs.contains(machineID),
            todayTokens: today.totalTokens,
            todayCostUSD: today.costUSD,
            topModel: Self.topModel(in: today)
        )
    }

    /// The raw model id with the most tokens in the window, or `nil` when the
    /// window is empty. Ties break on the model id (lexicographically smallest) so
    /// the pick is deterministic — never dependent on dictionary iteration order.
    private static func topModel(in today: WindowAggregate) -> String? {
        today.byModel
            .max { lhs, rhs in
                if lhs.value.totalTokens != rhs.value.totalTokens {
                    return lhs.value.totalTokens < rhs.value.totalTokens
                }
                return lhs.key > rhs.key
            }?
            .key
    }

    /// Today's burn descending, with a stable tiebreak so equal-burn machines
    /// (notably the all-zero 1-machine and fresh-install cases) keep a deterministic
    /// order: this Mac first, then label case-insensitively, then id.
    private static func ordered(_ lhs: MachineBreakdownRow, _ rhs: MachineBreakdownRow) -> Bool {
        if lhs.todayTokens != rhs.todayTokens { return lhs.todayTokens > rhs.todayTokens }
        if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
        let lhsLabel = lhs.label.lowercased()
        let rhsLabel = rhs.label.lowercased()
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
        return lhs.id < rhs.id
    }
}
