import BurnbarCore
import Foundation
import Observation

/// Loads usage from both providers (off the main actor), prices it, and
/// aggregates today's bucket for the popover. Refresh runs on launch and when
/// the popover opens; it posts `.burnbarDidRefresh` so `MenuBarController`
/// updates the status-item title.
///
/// Each provider is loaded independently — a missing `~/.codex` or unreadable
/// cache becomes a non-fatal warning, never blocking the other provider.
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
    /// Non-fatal per-provider load problems, surfaced in the UI.
    private(set) var warnings: [String] = []

    private let claude: ClaudeUsageProvider
    private let codex: CodexUsageProvider
    private let calculator: CostCalculator
    private let aggregator: TimeWindowAggregator

    init(
        claude: ClaudeUsageProvider = ClaudeUsageProvider(),
        codex: CodexUsageProvider = CodexUsageProvider(),
        calculator: CostCalculator = CostCalculator(),
        aggregator: TimeWindowAggregator = TimeWindowAggregator()
    ) {
        self.claude = claude
        self.codex = codex
        self.calculator = calculator
        self.aggregator = aggregator
    }

    /// Reload usage. No-op while a load is already in flight.
    ///
    /// The provider on/off flags from the Providers settings tab (1.5.6) are read
    /// fresh here, so toggling a provider and calling `refresh()` immediately
    /// drops/restores that provider's records (and therefore its popover tile).
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let providers = ProviderPreferences.load()
        Task {
            let snapshot = await Self.load(
                claude: claude,
                codex: codex,
                providers: providers,
                calculator: calculator,
                aggregator: aggregator
            )
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

    /// Runs off the main actor (nonisolated), so the blocking file/SQLite reads
    /// never stall the UI. Providers are value types (`Sendable`).
    ///
    /// A provider disabled in Settings (1.5.6) is skipped entirely — its parser
    /// never runs, so it contributes no records and no tile. The two-provider hard
    /// cap (CLAUDE.md) means this is exactly Claude and/or Codex; no other source
    /// is ever read.
    private nonisolated static func load(
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

        let priced = calculator.priced(records)
        // One pass produces all three windows; today/week/month feed the tiles
        // and the weekly/monthly burn bars (1.5.3).
        let windows = aggregator.aggregate(priced)
        return Snapshot(
            today: windows[.today],
            week: windows[.week],
            month: windows[.month],
            warnings: warnings
        )
    }
}
