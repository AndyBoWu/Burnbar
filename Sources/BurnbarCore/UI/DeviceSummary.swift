import Foundation

/// One row of the Settings → Devices table (Epic 2.4.4): a single machine's
/// display identity plus its today / all-time burn, ready for SwiftUI to render.
///
/// This is the pure, view-agnostic projection the `DevicesViewModel` (Burnbar
/// target) hands to the `Table`. Keeping it — and its assembly in
/// ``DeviceTableBuilder`` — in `BurnbarCore` makes the per-machine burn maths,
/// the local-Mac flagging, and the hidden/visible split unit-testable without
/// launching the app.
///
/// Privacy: a row carries only the opaque `machine_id`, a user/registry label, and
/// aggregate token + cost totals — never `cwd`, `git_*`, project dir names, model
/// detail, or any user content (the privacy thesis). The truncated id shown in the
/// table is derived here, not by the view.
public struct DeviceSummary: Sendable, Equatable, Identifiable {
    /// The opaque machine id (the `{machine_id}.jsonl` filename stem) — also the
    /// stable SwiftUI list identity.
    public let id: String

    /// Human-readable name: the user's rename (`MachineLabel` for this Mac, the
    /// `MachineRegistry` label for others), falling back to the id itself.
    public let label: String

    /// `true` when this row is the Mac the app is currently running on. The UI
    /// tags it "This Mac" and guards the forget action (forgetting the local file
    /// is allowed — it is recreated on the next write — but is confirmed clearly).
    public let isThisMac: Bool

    /// `true` when the user has hidden this machine (``HiddenMachines``). A hidden
    /// machine still appears in the table (flagged) but is excluded from the
    /// combined grand total.
    public let isHidden: Bool

    /// Today's total token burn across every provider/model for this machine.
    public let todayTokens: Int
    /// Today's total USD cost for this machine.
    public let todayCostUSD: Double

    /// All-time total token burn this machine has ever reported.
    public let totalTokens: Int
    /// All-time total USD cost for this machine.
    public let totalCostUSD: Double

    /// The machine's most-recent record day (`YYYY-MM-DD`), or `nil` when it has
    /// no records. Drives the "Last sync" column's relative text.
    public let lastRecordDay: String?

    public init(
        id: String,
        label: String,
        isThisMac: Bool,
        isHidden: Bool,
        todayTokens: Int,
        todayCostUSD: Double,
        totalTokens: Int,
        totalCostUSD: Double,
        lastRecordDay: String?
    ) {
        self.id = id
        self.label = label
        self.isThisMac = isThisMac
        self.isHidden = isHidden
        self.todayTokens = todayTokens
        self.todayCostUSD = todayCostUSD
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.lastRecordDay = lastRecordDay
    }

    /// The machine id truncated to its first 8 hex chars for compact display
    /// (full ids are 16 chars — see `MachineIdentity`). Privacy-safe: the id is
    /// already a one-way hash, and showing only a prefix keeps the table tidy.
    public var shortID: String {
        String(id.prefix(8))
    }
}

/// Assembles `DeviceSummary` rows from the raw multi-machine snapshot, the machine
/// registry, the hidden set, and a costing/aggregation pipeline (Epic 2.4.4).
///
/// Pure over its injected inputs — no I/O, no clock beyond the injected `now`, no
/// global state. The `DevicesViewModel` does the reading (off the main actor) and
/// hands the decoded `MachineUsage` list here; this folds each machine's records
/// into today + all-time burn and resolves the display label.
///
/// Label resolution mirrors the rename paths the ticket specifies: for **this**
/// Mac the `MachineLabel` override wins (the same store the "This Mac" row edits);
/// for **other** machines the `MachineRegistry` entry's label wins; either falls
/// back to the raw id when nothing friendlier exists. `Sendable` and stateless.
public struct DeviceTableBuilder: Sendable {
    private let calculator: CostCalculator
    private let aggregator: TimeWindowAggregator

    public init(
        calculator: CostCalculator = CostCalculator(),
        aggregator: TimeWindowAggregator = TimeWindowAggregator()
    ) {
        self.calculator = calculator
        self.aggregator = aggregator
    }

    /// The cross-cutting inputs shared by every row build: identity, label sources,
    /// hidden set, and the "today" reference instant. Bundled so the build entry
    /// point stays a single argument and the per-machine fold reads from one place.
    public struct Context: Sendable {
        /// This Mac's id, so its row is flagged and labelled from `MachineLabel`.
        public let thisMachineID: String
        /// The resolved friendly name for this Mac (`MachineLabel.label`), used in
        /// place of the registry label for the local row so renames in the "This
        /// Mac" section reflect immediately.
        public let thisMachineLabel: String
        /// `[machine_id: label]` from `MachineRegistry`, used for every other
        /// machine.
        public let registryLabels: [String: String]
        /// The user's hidden set (`HiddenMachines.hiddenIDs()`).
        public let hiddenIDs: Set<String>
        /// Reference instant for the "today" window (injectable for tests).
        public let now: Date

        public init(
            thisMachineID: String,
            thisMachineLabel: String,
            registryLabels: [String: String],
            hiddenIDs: Set<String>,
            now: Date = Date()
        ) {
            self.thisMachineID = thisMachineID
            self.thisMachineLabel = thisMachineLabel
            self.registryLabels = registryLabels
            self.hiddenIDs = hiddenIDs
            self.now = now
        }
    }

    /// Build the table rows from per-machine snapshots (from
    /// `MultiMachineReader.readMachines()`) and the shared ``Context``.
    ///
    /// - Returns: one row per machine, sorted with this Mac first, then by label
    ///   (case-insensitive), then by id — a stable, human-friendly ordering.
    public func rows(from machines: [MachineUsage], context: Context) -> [DeviceSummary] {
        machines
            .map { row(for: $0, context: context) }
            .sorted(by: Self.ordered)
    }

    private func row(for machine: MachineUsage, context: Context) -> DeviceSummary {
        let priced = calculator.priced(machine.records)
        let today = aggregator.aggregate(priced, window: .today, now: context.now)
        let totalTokens = priced.reduce(0) { $0 + $1.totalTokens }
        let totalCost = priced.reduce(0.0) { $0 + ($1.costUSD ?? 0) }

        let isThisMac = machine.machineID == context.thisMachineID
        let label: String = if isThisMac {
            context.thisMachineLabel
        } else {
            context.registryLabels[machine.machineID] ?? machine.machineID
        }

        return DeviceSummary(
            id: machine.machineID,
            label: label,
            isThisMac: isThisMac,
            isHidden: context.hiddenIDs.contains(machine.machineID),
            todayTokens: today.totalTokens,
            todayCostUSD: today.costUSD,
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            lastRecordDay: machine.lastRecordDay
        )
    }

    /// This Mac first, then by label (case-insensitive), then by id as a tiebreak.
    private static func ordered(_ lhs: DeviceSummary, _ rhs: DeviceSummary) -> Bool {
        if lhs.isThisMac != rhs.isThisMac { return lhs.isThisMac }
        let lhsLabel = lhs.label.lowercased()
        let rhsLabel = rhs.label.lowercased()
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
        return lhs.id < rhs.id
    }
}
