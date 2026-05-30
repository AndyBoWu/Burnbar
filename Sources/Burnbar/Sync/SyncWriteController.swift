import AppKit
import BurnbarCore
import Foundation

/// App-side driver for the M2 iCloud write scheduler (2.2.4).
///
/// Keeps this machine's `{machine_id}.jsonl` rollup fresh — so a second Mac sees
/// near-current data — by asking a ``SyncWriteCoordinator`` to write on three
/// triggers, exactly as the ticket specifies:
///   - a repeating `Timer` (cadence from the refresh-rate preference, or 5 min),
///   - app quit (`NSApplication.willTerminateNotification`), with a final
///     synchronous flush before the process exits, and
///   - system wake (`NSWorkspace.shared.notificationCenter` `didWakeNotification`).
///
/// `AppDelegate` creates exactly one of these at launch. This object only handles
/// AppKit lifecycle wiring and trigger plumbing on the main actor; all blocking
/// work — resolving the iCloud directory (`ICloudContainer.resolve()` blocks),
/// loading + pricing usage, and the atomic file write — happens inside the
/// injected `SyncWriteCoordinator` (an `actor`), which never runs on the main
/// thread and serializes overlapping triggers itself.
///
/// It deliberately touches neither the popover views nor `MenuBarController`'s
/// status-item code — it is a standalone background concern.
@MainActor
final class SyncWriteController {
    private let coordinator: SyncWriteCoordinator
    /// How often the repeating timer fires; resolved once from the refresh-rate
    /// preference at construction (5-minute default).
    private let interval: TimeInterval
    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - coordinator: the write engine. Defaults to a production coordinator
    ///     wired to the real iCloud container, the same Claude + Codex providers
    ///     `UsageStore` uses (priced via `CostCalculator`, all days loaded),
    ///     `MachineIdentity`, and the atomic `DailyRollupWriter`.
    ///   - interval: repeating-timer cadence. Defaults to the value derived from
    ///     the stored refresh-rate preference.
    ///   - notificationCenter: source of the quit notification (default: the
    ///     app's `.default` center).
    ///   - workspaceCenter: source of the wake notification (default:
    ///     `NSWorkspace.shared.notificationCenter`).
    init(
        coordinator: SyncWriteCoordinator = SyncWriteController.makeProductionCoordinator(),
        interval: TimeInterval = SyncWriteController.preferredInterval(),
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.coordinator = coordinator
        self.interval = interval
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
    }

    // MARK: - Lifecycle

    /// Begin scheduling: install the repeating timer plus the quit and wake
    /// observers, and perform one immediate write so the rollup is fresh at
    /// launch. Safe to call once; `AppDelegate` owns the single instance.
    func start() {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the actor for the write.
            Task { await self?.coordinator.write() }
        }
        // Keep firing while menus/modal panels are up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observers.append(
            notificationCenter.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeSynchronouslyOnQuit() }
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.coordinator.write() }
            }
        )

        // Launch write: don't wait until the first interval elapses.
        Task { await coordinator.write() }
    }

    /// Tear down the timer and observers. Called from tests; the app keeps the
    /// controller alive for its whole lifetime.
    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            notificationCenter.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Quit flush

    /// On `applicationWillTerminate`, the process is about to exit, so a detached
    /// `Task` would be killed before its write lands. Block the main thread until
    /// the final write completes (or a short timeout elapses) so the rollup
    /// captures the latest usage before quit.
    private func writeSynchronouslyOnQuit() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [coordinator] in
            await coordinator.write()
            semaphore.signal()
        }
        // Bounded wait: never hang the quit sequence if the write stalls (e.g. a
        // slow iCloud volume). 5s mirrors a typical terminate grace window.
        _ = semaphore.wait(timeout: .now() + 5)
    }

    // MARK: - Production wiring

    /// The repeating-timer cadence from the stored refresh-rate preference
    /// (5-minute default when unset), via the pure ``SyncWriteSchedule`` helper.
    static func preferredInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let raw = defaults.string(forKey: PreferenceKeys.refreshInterval)
        let preference = raw.map { RefreshInterval.fromStorage($0) }
        return SyncWriteSchedule.interval(for: preference)
    }

    /// Build the production coordinator: real iCloud container, the same provider
    /// set `UsageStore` loads (respecting the per-provider on/off toggles),
    /// priced via `CostCalculator`, all days, the atomic `DailyRollupWriter`, and
    /// the `UserDefaults`-backed `last-write-at` store.
    static func makeProductionCoordinator() -> SyncWriteCoordinator {
        let container = ICloudContainer()
        let claude = ClaudeUsageProvider()
        let codex = CodexUsageProvider()
        let calculator = CostCalculator()

        return SyncWriteCoordinator(
            resolveLocation: { container.resolve() },
            loadRecords: {
                // Same providers/toggles UsageStore uses; price every record;
                // load ALL days (providers already return the full history).
                let providers = ProviderPreferences.load()
                var records: [UsageRecord] = []
                if providers.isEnabled(.claude) {
                    records += try claude.usageRecords()
                }
                if providers.isEnabled(.codex) {
                    records += try codex.usageRecords()
                }
                return calculator.priced(records)
            },
            machineID: { MachineIdentity.current() },
            writeRollup: { records, directory, machineID in
                try DailyRollupWriter(directory: directory).write(records: records, machineID: machineID)
            },
            store: UserDefaultsLastWriteStore()
        )
    }
}
