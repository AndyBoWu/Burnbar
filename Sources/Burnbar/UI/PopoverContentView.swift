import AppKit
import BurnbarCore
import SwiftUI

/// The popover's glance UI: a header, one `ProviderTileView` per provider for
/// today's usage, a last-updated line, and a quick-action row (1.5.4) with
/// Refresh now / Settings… / Quit. Burn bars (1.5.3) sit between the tiles and
/// the actions.
struct PopoverContentView: View {
    @Bindable var store: UsageStore

    private var hasAnyData: Bool {
        guard let today = store.today else { return false }
        return !today.byProvider.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            modePicker

            if store.viewMode == .allMacs {
                syncingBadge
            }

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

    /// "This Mac | All Macs" segmented control (2.4.1). Bound straight to
    /// `store.viewMode`: flipping it persists the choice (the store writes the
    /// `popover.viewMode` default) and reloads from the matching data source, so
    /// the tiles and burn bars re-render in place without a restart.
    private var modePicker: some View {
        Picker("View", selection: $store.viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// "N Macs syncing" badge (2.4.2), shown only in All-Macs mode. The count is
    /// `store.machineCount` — the number of machines reconciled into the combined
    /// total — so the badge and the summed burn it sits above always agree. The
    /// `SyncingBadge` helper owns the singular/plural wording.
    ///
    /// Note: the expandable per-machine breakdown (2.4.3) is intentionally not built
    /// here — this is the badge + count only, per the ticket's scope split.
    private var syncingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
            Text(SyncingBadge.text(machineCount: store.machineCount))
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.10), in: Capsule())
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
