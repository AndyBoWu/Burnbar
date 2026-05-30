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

    /// `true` while a manual "Force resync" (2.5.3) is in flight, so the view can
    /// disable the button and show a spinner. Separate from ``isLoading`` because a
    /// resync is a write-then-read, not a plain table reload.
    private(set) var isResyncing = false

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

    /// Builds the ``ForceResync`` driver for one manual resync (2.5.3). Injected so
    /// tests can supply a fake (no real iCloud / providers); production wires the
    /// shared write coordinator + a fresh multi-machine read against the resolved
    /// iCloud directory. Invoked on the main actor (the heavy work runs inside the
    /// returned driver's async closures, off-main).
    private let makeForceResync: @MainActor () -> ForceResync

    init(
        iCloudContainer: ICloudContainer = ICloudContainer(),
        registry: MachineRegistry = MachineRegistry(),
        hiddenStore: HiddenMachines = HiddenMachines(),
        labelStore: MachineLabel = MachineLabel(),
        builder: DeviceTableBuilder = DeviceTableBuilder(),
        defaults: UserDefaults = .standard,
        makeForceResync: @escaping @MainActor () -> ForceResync = DevicesViewModel.productionForceResync
    ) {
        self.iCloudContainer = iCloudContainer
        self.registry = registry
        self.hiddenStore = hiddenStore
        self.labelStore = labelStore
        self.builder = builder
        self.defaults = defaults
        self.makeForceResync = makeForceResync
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
    private struct LoadResult {
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

    // MARK: - Force resync (2.5.3)

    /// Manual "Force resync": force an immediate rollup WRITE of this machine's
    /// `{machine_id}.jsonl`, then a READ refresh of the fleet table and the
    /// combined view. No-op while a resync is already in flight (the button is
    /// also disabled), so a double-tap can't launch two writes.
    ///
    /// The write-then-read sequence and its structured `SyncLog` line run off the
    /// main actor inside ``ForceResync`` (the coordinator is an `actor`; the read
    /// is plain file I/O), so the main thread is never blocked. On completion this
    /// posts `.burnbarSettingsDidChange` — which the popover's combined view and
    /// the `SyncHealth` monitor already observe — and reloads this table, so the
    /// UI reflects the fresh data immediately. Targets the DoD's ~3-second budget.
    func forceResync() {
        guard !isResyncing else { return }
        isResyncing = true

        let resync = makeForceResync()
        Task {
            await resync.run()
            // The fresh write + re-read landed: tell the combined view / sync
            // health to re-read, and reload our own table.
            NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
            isResyncing = false
            refresh()
        }
    }

    /// Production ``ForceResync`` factory: drive the shared write coordinator's
    /// manual trigger, then re-read every machine's rollup from the resolved
    /// iCloud directory, logging to the real `~/Library/Logs/Burnbar/sync.log`.
    ///
    /// Both the write (coordinator is an `actor`) and the read (`ICloudContainer`
    /// resolve + file enumeration block) run inside the injected async closures,
    /// off the main thread.
    @MainActor
    static func productionForceResync() -> ForceResync {
        let coordinator = SyncWriteController.makeProductionCoordinator()
        let container = ICloudContainer()
        return ForceResync(
            write: { await coordinator.forceWrite() },
            readMachineCount: {
                await Task.detached {
                    guard let directory = container.resolve().url else { return 0 }
                    return MultiMachineReader(directory: directory).readMachines().count
                }.value
            }
        )
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
