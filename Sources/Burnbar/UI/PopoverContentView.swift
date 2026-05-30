import BurnbarCore
import SwiftUI

/// The popover's glance UI: a header, one `ProviderTileView` per provider for
/// today's usage, and a footer with the last-updated time. Burn bars (1.5.3)
/// and the full quick-action row (1.5.4) extend this.
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

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
