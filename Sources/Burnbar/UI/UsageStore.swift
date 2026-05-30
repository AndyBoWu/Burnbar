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
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let snapshot = await Self.load(
                claude: claude,
                codex: codex,
                calculator: calculator,
                aggregator: aggregator
            )
            today = snapshot.today
            warnings = snapshot.warnings
            lastUpdated = Date()
            isLoading = false
            NotificationCenter.default.post(name: .burnbarDidRefresh, object: nil)
        }
    }

    private struct Snapshot {
        var today: WindowAggregate?
        var warnings: [String]
    }

    /// Runs off the main actor (nonisolated), so the blocking file/SQLite reads
    /// never stall the UI. Providers are value types (`Sendable`).
    private nonisolated static func load(
        claude: ClaudeUsageProvider,
        codex: CodexUsageProvider,
        calculator: CostCalculator,
        aggregator: TimeWindowAggregator
    ) async -> Snapshot {
        var records: [UsageRecord] = []
        var warnings: [String] = []

        do {
            records += try claude.usageRecords()
        } catch {
            warnings.append("Claude: \(error.localizedDescription)")
        }
        do {
            records += try codex.usageRecords()
        } catch {
            warnings.append("Codex: \(error.localizedDescription)")
        }

        let priced = calculator.priced(records)
        let today = aggregator.aggregate(priced, window: .today)
        return Snapshot(today: today, warnings: warnings)
    }
}
