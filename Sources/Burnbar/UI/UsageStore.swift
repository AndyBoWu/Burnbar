import BurnbarCore
import Foundation
import Observation

/// Loads usage, prices it, and aggregates the today/week/month buckets for the
/// popover. Refresh runs on launch and when the popover opens; it posts
/// `.burnbarDidRefresh` so `MenuBarController` updates the status-item title.
///
/// Two data sources back the same three windows, chosen by ``viewMode`` (2.4.1):
///
/// - **This Mac** (`.thisMac`) — the original local read: both providers loaded
///   off the main actor, each independently so a missing `~/.codex` or unreadable
///   cache becomes a non-fatal warning, never blocking the other provider.
/// - **All Macs** (`.allMacs`) — the cross-device combined view: resolve the
///   shared iCloud directory (`ICloudContainer.resolve()`, which blocks, so it
///   runs off main), read every machine's rollup (`MultiMachineReader`), reconcile
///   into one daily view (`Reconciler.merge`), then price and aggregate exactly
///   like the local path. The tiles and burn bars render whichever source the
///   current mode selects.
///
/// All blocking I/O for both paths happens in the `nonisolated` loaders, so the
/// UI never stalls. Flipping ``viewMode`` persists the choice and re-loads in
/// place, so the popover updates without a restart.
@MainActor
@Observable
final class UsageStore {
    /// Today's aggregated usage (per-provider + per-model breakdown), or `nil`
    /// before the first successful load.
    private(set) var today: WindowAggregate?
    /// This week's aggregated usage, feeding the weekly burn bar (1.5.3).
    private(set) var week: WindowAggregate?
    /// This month's aggregated usage, feeding the monthly burn bar (1.5.3).
    private(set) var month: WindowAggregate?
    /// When the last load completed, for the "updated N ago" footer.
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    /// Non-fatal load problems (per-provider, or the iCloud read), surfaced in the UI.
    private(set) var warnings: [String] = []

    /// Whether the popover shows this machine only or every machine combined
    /// (2.4.1). Initialized from `UserDefaults`; assigning a new value persists
    /// the choice and reloads from the matching data source in place, so the
    /// tiles and bars switch without a restart.
    var viewMode: ViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            defaults.set(viewMode.rawValue, forKey: ViewMode.storageKey)
            refresh()
        }
    }

    private let claude: ClaudeUsageProvider
    private let codex: CodexUsageProvider
    private let calculator: CostCalculator
    private let aggregator: TimeWindowAggregator
    private let iCloudContainer: ICloudContainer
    private let reconciler: Reconciler
    private let defaults: UserDefaults

    init(
        claude: ClaudeUsageProvider = ClaudeUsageProvider(),
        codex: CodexUsageProvider = CodexUsageProvider(),
        calculator: CostCalculator = CostCalculator(),
        aggregator: TimeWindowAggregator = TimeWindowAggregator(),
        iCloudContainer: ICloudContainer = ICloudContainer(),
        reconciler: Reconciler = Reconciler(),
        defaults: UserDefaults = .standard
    ) {
        self.claude = claude
        self.codex = codex
        self.calculator = calculator
        self.aggregator = aggregator
        self.iCloudContainer = iCloudContainer
        self.reconciler = reconciler
        self.defaults = defaults
        viewMode = ViewMode.fromStorage(defaults.string(forKey: ViewMode.storageKey))
    }

    /// Reload usage from the current ``viewMode``'s data source. No-op while a
    /// load is already in flight.
    ///
    /// The provider on/off flags from the Providers settings tab (1.5.6) are read
    /// fresh here, so toggling a provider and calling `refresh()` immediately
    /// drops/restores that provider's records (and therefore its popover tile).
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let providers = ProviderPreferences.load(from: defaults)
        let mode = viewMode
        Task {
            let snapshot: Snapshot
            switch mode {
            case .thisMac:
                snapshot = await Self.loadThisMac(
                    claude: claude,
                    codex: codex,
                    providers: providers,
                    calculator: calculator,
                    aggregator: aggregator
                )
            case .allMacs:
                snapshot = await Self.loadAllMacs(
                    iCloudContainer: iCloudContainer,
                    reconciler: reconciler,
                    calculator: calculator,
                    aggregator: aggregator
                )
            }
            today = snapshot.today
            week = snapshot.week
            month = snapshot.month
            warnings = snapshot.warnings
            lastUpdated = Date()
            isLoading = false
            NotificationCenter.default.post(name: .burnbarDidRefresh, object: nil)
        }
    }

    private struct Snapshot {
        var today: WindowAggregate?
        var week: WindowAggregate?
        var month: WindowAggregate?
        var warnings: [String]
    }

    /// Collapse priced records into the three windows. Shared tail of both load
    /// paths: one aggregation pass produces today/week/month for the tiles and the
    /// weekly/monthly burn bars (1.5.3).
    private nonisolated static func snapshot(
        from records: [UsageRecord],
        warnings: [String],
        calculator: CostCalculator,
        aggregator: TimeWindowAggregator
    ) -> Snapshot {
        let priced = calculator.priced(records)
        let windows = aggregator.aggregate(priced)
        return Snapshot(
            today: windows[.today],
            week: windows[.week],
            month: windows[.month],
            warnings: warnings
        )
    }

    /// **This Mac** path. Runs off the main actor (nonisolated), so the blocking
    /// file/SQLite reads never stall the UI. Providers are value types (`Sendable`).
    ///
    /// A provider disabled in Settings (1.5.6) is skipped entirely — its parser
    /// never runs, so it contributes no records and no tile. The two-provider hard
    /// cap (CLAUDE.md) means this is exactly Claude and/or Codex; no other source
    /// is ever read.
    private nonisolated static func loadThisMac(
        claude: ClaudeUsageProvider,
        codex: CodexUsageProvider,
        providers: ProviderPreferences,
        calculator: CostCalculator,
        aggregator: TimeWindowAggregator
    ) async -> Snapshot {
        var records: [UsageRecord] = []
        var warnings: [String] = []

        if providers.isEnabled(.claude) {
            do {
                records += try claude.usageRecords()
            } catch {
                warnings.append("Claude: \(error.localizedDescription)")
            }
        }
        if providers.isEnabled(.codex) {
            do {
                records += try codex.usageRecords()
            } catch {
                warnings.append("Codex: \(error.localizedDescription)")
            }
        }

        return snapshot(from: records, warnings: warnings, calculator: calculator, aggregator: aggregator)
    }

    /// **All Macs** path. Runs off the main actor (nonisolated): resolving the
    /// iCloud directory blocks, so it must not touch the main thread.
    ///
    /// Resolves the shared `Burnbar/` directory, reads every machine's rollup,
    /// reconciles them into one combined daily view, then prices + aggregates that
    /// combined record set — so the same tiles and burn bars render the grand
    /// total across devices. When iCloud is unavailable (Drive off / signed out)
    /// the combined view is empty and a single non-fatal warning explains why,
    /// matching the local path's "missing source is a warning, not a crash" rule.
    private nonisolated static func loadAllMacs(
        iCloudContainer: ICloudContainer,
        reconciler: Reconciler,
        calculator: CostCalculator,
        aggregator: TimeWindowAggregator
    ) async -> Snapshot {
        let location = iCloudContainer.resolve()
        guard let directory = location.url else {
            let reason: String
            if case let .unavailable(message) = location {
                reason = message
            } else {
                reason = "iCloud is unavailable."
            }
            return Snapshot(today: nil, week: nil, month: nil, warnings: ["All Macs: \(reason)"])
        }

        let byMachine = MultiMachineReader(directory: directory).readAll()
        let reconciled = reconciler.merge(byMachine)
        return snapshot(from: reconciled.combined, warnings: [], calculator: calculator, aggregator: aggregator)
    }
}
