import BurnbarCore
import Foundation
import Observation

/// Backs the Settings → Devices full table (Epic 2.4.4): loads every machine's
/// rollup from the shared iCloud directory, computes per-machine today / all-time
/// burn, and owns the rename / hide / forget lifecycle actions.
///
/// Deliberately separate from `UsageStore` and the popover — this view-model is
/// scoped to the Settings window's fleet-management surface and must not perturb
/// the menu-bar read path (which is why it is a new type, per the ticket).
///
/// **Concurrency.** `@MainActor` so its `@Observable` state is touched only on the
/// main thread, but all blocking I/O — resolving the iCloud directory
/// (`ICloudContainer.resolve()` blocks), enumerating + decoding every
/// `{machine_id}.jsonl` — runs in a `nonisolated` loader hopped off the main
/// actor. The pure assembly (`DeviceTableBuilder`) and costing/aggregation live in
/// `BurnbarCore` and are unit-tested there; this object only orchestrates the
/// reads and persists the action results.
///
/// **Privacy.** Surfaces only machine label + truncated id + aggregate burn. It
/// never reads or displays `cwd`, `git_*`, project dir names, or any user content,
/// and the ids/labels never leave the device (the privacy thesis).
@MainActor
@Observable
final class DevicesViewModel {
    /// One row per known machine, sorted (this Mac first, then by label). Empty
    /// before the first load and whenever iCloud is unreachable.
    private(set) var devices: [DeviceSummary] = []

    /// `true` while a load is in flight, so the view can show progress and avoid
    /// re-entrant reads.
    private(set) var isLoading = false

    /// A non-fatal explanation when the fleet can't be read (iCloud Drive off /
    /// signed out). `nil` on a clean load. Matches the popover's "missing source
    /// is a warning, not a crash" rule.
    private(set) var warning: String?

    /// This Mac's stable machine id — its row is flagged "This Mac" and labelled
    /// from `MachineLabel` so the "This Mac" section's rename reflects here too.
    let thisMachineID = MachineIdentity.current()

    private let iCloudContainer: ICloudContainer
    private let registry: MachineRegistry
    private let hiddenStore: HiddenMachines
    private let labelStore: MachineLabel
    private let builder: DeviceTableBuilder
    private let defaults: UserDefaults

    init(
        iCloudContainer: ICloudContainer = ICloudContainer(),
        registry: MachineRegistry = MachineRegistry(),
        hiddenStore: HiddenMachines = HiddenMachines(),
        labelStore: MachineLabel = MachineLabel(),
        builder: DeviceTableBuilder = DeviceTableBuilder(),
        defaults: UserDefaults = .standard
    ) {
        self.iCloudContainer = iCloudContainer
        self.registry = registry
        self.hiddenStore = hiddenStore
        self.labelStore = labelStore
        self.builder = builder
        self.defaults = defaults
    }

    // MARK: - Loading

    /// Reload the table from the shared iCloud directory. No-op while a load is
    /// already running. Resolving + reading happens off the main actor; only the
    /// final assignment touches `@Observable` state on the main thread.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        let container = iCloudContainer
        let builder = builder
        let context = DeviceTableBuilder.Context(
            thisMachineID: thisMachineID,
            thisMachineLabel: labelStore.label,
            registryLabels: registryLabelMap(),
            hiddenIDs: hiddenStore.hiddenIDs()
        )

        Task {
            let result = await Self.load(container: container, builder: builder, context: context)
            devices = result.devices
            warning = result.warning
            isLoading = false
        }
    }

    /// The outcome of one off-main load: the assembled rows plus an optional
    /// non-fatal warning.
    private struct LoadResult: Sendable {
        let devices: [DeviceSummary]
        let warning: String?
    }

    /// **Off the main actor.** Resolve the iCloud directory (blocks), read every
    /// machine's rollup, and fold each into a `DeviceSummary`. A missing /
    /// unavailable iCloud location yields an empty table and a warning, never a
    /// crash.
    private nonisolated static func load(
        container: ICloudContainer,
        builder: DeviceTableBuilder,
        context: DeviceTableBuilder.Context
    ) async -> LoadResult {
        let location = container.resolve()
        guard let directory = location.url else {
            let reason: String = if case let .unavailable(message) = location {
                message
            } else {
                "iCloud is unavailable."
            }
            return LoadResult(devices: [], warning: reason)
        }

        let machines = MultiMachineReader(directory: directory).readMachines()
        let rows = builder.rows(from: machines, context: context)
        return LoadResult(devices: rows, warning: nil)
    }

    // MARK: - Actions

    /// Rename a machine, persisting the change and refreshing the row in place.
    ///
    /// The local Mac routes through `MachineLabel` (the same store the "This Mac"
    /// section edits), so a rename here and there stay in sync. Other machines go
    /// through `MachineRegistry.rename`, which only ever rewrites the label — never
    /// `lastSeen` — so the rename survives the reader re-surfacing the machine.
    func rename(_ machineID: String, to newLabel: String) {
        if machineID == thisMachineID {
            labelStore.rename(to: newLabel)
        } else {
            let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty rename for a remote machine would erase its only friendly
            // name; ignore it so the row keeps its existing label rather than
            // reverting to the raw id.
            guard !trimmed.isEmpty else { return }
            registry.rename(machineID: machineID, to: trimmed)
        }
        refresh()
    }

    /// Toggle a machine's hidden state, persisting it and refreshing. A hidden
    /// machine is excluded from the combined grand total (`UsageStore`'s All-Macs
    /// path consults `HiddenMachines`); it stays in this table, flagged, so the
    /// user can unhide it. Posts `.burnbarSettingsDidChange` so the popover's
    /// combined view re-reads.
    func toggleHidden(_ machineID: String) {
        hiddenStore.toggle(machineID)
        NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
        refresh()
    }

    /// Forget a machine: delete its `{machine_id}.jsonl` from the shared iCloud
    /// directory, drop it from the hidden set, and refresh.
    ///
    /// Each machine owns exactly one file, so deleting one machine's rollup can
    /// never corrupt another's (the conflict-free file-per-machine invariant). The
    /// local Mac's own file is safe to delete — the write scheduler (Epic 2.2)
    /// recreates it on the next rollup — but the caller (the view) confirms first
    /// via a dialog, per the Definition of Done.
    ///
    /// File deletion blocks (iCloud resolve + remove), so it runs off the main
    /// actor; the post-delete refresh hops back to update the table.
    func forget(_ machineID: String) {
        let container = iCloudContainer
        let hiddenStore = hiddenStore

        Task {
            await Self.deleteRollup(for: machineID, container: container)
            // Clear any stale hidden flag so a future re-sighting isn't silently
            // re-hidden by a lingering id.
            hiddenStore.forget(machineID)
            NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
            refresh()
        }
    }

    /// **Off the main actor.** Resolve the shared directory and delete exactly the
    /// one `{machine_id}.jsonl` file. A missing file or unavailable iCloud is a
    /// no-op (the row simply disappears on refresh), never a crash.
    private nonisolated static func deleteRollup(
        for machineID: String,
        container: ICloudContainer
    ) async {
        await Task.detached {
            guard let directory = container.resolve().url else { return }
            let file = directory.appendingPathComponent("\(machineID).jsonl", isDirectory: false)
            try? FileManager.default.removeItem(at: file)
        }.value
    }

    // MARK: - Helpers

    /// `[machine_id: label]` snapshot of the registry, for the off-main builder.
    private func registryLabelMap() -> [String: String] {
        var map: [String: String] = [:]
        for entry in registry.all() {
            map[entry.id] = entry.label
        }
        return map
    }
}
