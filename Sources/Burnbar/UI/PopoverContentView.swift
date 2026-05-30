import AppKit
import BurnbarCore
import SwiftUI

/// The popover's glance UI: a header, one `ProviderTileView` per provider for
/// today's usage, a last-updated line, and a quick-action row (1.5.4) with
/// Refresh now / Settings… / Quit. Burn bars (1.5.3) sit between the tiles and
/// the actions.
struct PopoverContentView: View {
    let store: UsageStore

    private var hasAnyData: Bool {
        guard let today = store.today else { return false }
        return !today.byProvider.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if hasAnyData, let today = store.today {
                ForEach(Provider.allCases) { provider in
                    ProviderTileView(provider: provider, model: ProviderTileModel.make(provider: provider, from: today))
                }
                burnBars
            } else {
                emptyState
            }

            if !store.warnings.isEmpty {
                ForEach(store.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Weekly + monthly burn bars (1.5.3) fed by the real week/month token
    /// totals from the aggregator.
    ///
    /// Note: the `.fiveHour` window is intentionally NOT wired here. `UsageRecord`
    /// is day-granular (no sub-day timestamps), so a true rolling 5-hour token
    /// total is not computable from our data. `BurnBarView` and `ResetClock` both
    /// support `.fiveHour` so it can be enabled once a finer-grained source
    /// exists, but rendering it now would show a misleading number.
    private var burnBars: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Limits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let week = store.week {
                BurnBarView(
                    value: week.totalTokens,
                    limit: BurnBudget.weeklyTokens,
                    window: .weekly
                )
            }
            if let month = store.month {
                BurnBarView(
                    value: month.totalTokens,
                    limit: BurnBudget.monthlyTokens,
                    window: .monthly
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
            Text("Burnbar").font(.headline)
            Spacer()
            Text("Today").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame").font(.title2).foregroundStyle(.tertiary)
            Text("No data yet")
                .font(.subheadline.weight(.medium))
            Text("Use Claude Code or Codex and your burn shows up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// Last-updated line plus the quick-action row (1.5.4). Every action is one
    /// click: "Refresh now" re-reads usage (which posts `.burnbarDidRefresh` so
    /// tiles/bars update), "Settings…" opens the SwiftUI `Settings` scene, and
    /// "Quit" terminates the agent. The same three actions back the status item's
    /// right-click menu in `MenuBarController`.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)

                Button {
                    MenuActions.openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Spacer()

                Button {
                    MenuActions.quit()
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .labelStyle(.titleOnly)
            .controlSize(.small)
        }
    }

    private var updatedText: String {
        guard let lastUpdated = store.lastUpdated else {
            return store.isLoading ? "Loading…" : "Not loaded yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated " + formatter.localizedString(for: lastUpdated, relativeTo: Date())
    }
}
