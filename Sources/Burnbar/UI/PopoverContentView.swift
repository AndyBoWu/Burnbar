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
                if store.isBreakdownExpanded {
                    MachineBreakdownView(rows: store.machineBreakdown)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
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
    /// In 2.4.3 the badge doubles as the disclosure control for the per-machine
    /// breakdown panel: tapping it toggles `store.isBreakdownExpanded` (animated),
    /// and a trailing chevron flips to signal the state. The badge is only an active
    /// disclosure when there are machines to break down — with no rows it stays a
    /// plain, non-interactive label.
    private var syncingBadge: some View {
        let canExpand = !store.machineBreakdown.isEmpty
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.isBreakdownExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                Text(SyncingBadge.text(machineCount: store.machineCount))
                    .font(.caption2.weight(.medium))
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(store.isBreakdownExpanded ? 90 : 0))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityLabel(SyncingBadge.text(machineCount: store.machineCount))
        .accessibilityHint(canExpand ? "Shows the per-machine breakdown" : "")
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

/// The expandable per-machine breakdown panel (2.4.3), shown under the syncing
/// badge in All-Macs mode when expanded. One ``MachineBreakdownRowView`` per
/// machine, already sorted by today's burn descending by ``MachineBreakdownBuilder``.
///
/// Sized to read well for the 1–5 machine range the ticket targets: rows stay
/// inline, but a `ScrollView` capped at a max height keeps the popover bounded if a
/// larger fleet ever appears, so nothing clips or overflows.
struct MachineBreakdownView: View {
    let rows: [MachineBreakdownRow]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    MachineBreakdownRowView(row: row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: rows.count > 5 ? 180 : .infinity)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A single machine's row in the breakdown panel: its label (or short id), a "This
/// Mac" / "(stale)" tag, today's spend, and today's token total with the top model.
/// Stale machines are dimmed and suffixed "(stale)" per the DoD.
struct MachineBreakdownRowView: View {
    let row: MachineBreakdownRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isThisMac {
                        tag("This Mac")
                    }
                    if row.isStale {
                        tag("stale")
                    }
                }
                Text(detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(BurnFormat.cost(row.todayCostUSD))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .opacity(row.isStale ? 0.55 : 1)
    }

    /// The display name — the friendly label, or the truncated id when the label
    /// is just the raw machine id (no friendlier name resolved yet).
    private var name: String {
        row.label == row.id ? row.shortID : row.label
    }

    /// "12.3K tokens · claude-opus-4-7" — today's token total plus the top model,
    /// or just the token total when the machine has no usage today.
    private var detailLine: String {
        let tokens = "\(BurnFormat.tokens(row.todayTokens)) tokens"
        guard let model = row.topModel else { return tokens }
        return "\(tokens)  ·  \(model)"
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Previews

#if DEBUG
/// Previews the breakdown panel across the 1–5 machine range the DoD calls out, so
/// layout (no clipping/overflow; the stale dim; the "This Mac" tag) can be eyeballed
/// without launching the app.
#Preview("Breakdown · 1 machine") {
    MachineBreakdownView(rows: [
        MachineBreakdownRow(
            id: "a1b2c3d4e5f60718",
            label: "MacBook Pro",
            isThisMac: true,
            isStale: false,
            todayTokens: 1_240_000,
            todayCostUSD: 4.82,
            topModel: "claude-opus-4-7"
        )
    ])
    .padding()
    .frame(width: 300)
}

#Preview("Breakdown · 2 machines") {
    MachineBreakdownView(rows: [
        MachineBreakdownRow(
            id: "a1b2c3d4e5f60718",
            label: "MacBook Pro",
            isThisMac: true,
            isStale: false,
            todayTokens: 1_240_000,
            todayCostUSD: 4.82,
            topModel: "claude-opus-4-7"
        ),
        MachineBreakdownRow(
            id: "f0e1d2c3b4a59687",
            label: "Mac Studio",
            isThisMac: false,
            isStale: false,
            todayTokens: 86200,
            todayCostUSD: 0.31,
            topModel: "gpt-5"
        )
    ])
    .padding()
    .frame(width: 300)
}

#Preview("Breakdown · 5 machines") {
    MachineBreakdownView(rows: [
        previewRow(
            id: "1111111111111111", label: "MacBook Pro", isThisMac: true,
            tokens: 1_240_000, cost: 4.82, model: "claude-opus-4-7"
        ),
        previewRow(id: "2222222222222222", label: "Mac Studio", tokens: 642_000, cost: 2.10, model: "claude-sonnet-4"),
        previewRow(id: "3333333333333333", label: "Mac mini", tokens: 86200, cost: 0.31, model: "gpt-5"),
        previewRow(id: "4444444444444444", label: "iMac", tokens: 4100, cost: 0.01, model: "claude-haiku-4"),
        previewRow(id: "5555555555555555", label: "Old Air", isStale: true, tokens: 0, cost: 0, model: nil)
    ])
    .padding()
    .frame(width: 300)
}

/// Compact `MachineBreakdownRow` factory for the previews above, so each preview
/// row stays under the line-length limit.
private func previewRow(
    id: String,
    label: String,
    isThisMac: Bool = false,
    isStale: Bool = false,
    tokens: Int,
    cost: Double,
    model: String?
) -> MachineBreakdownRow {
    MachineBreakdownRow(
        id: id,
        label: label,
        isThisMac: isThisMac,
        isStale: isStale,
        todayTokens: tokens,
        todayCostUSD: cost,
        topModel: model
    )
}
#endif
