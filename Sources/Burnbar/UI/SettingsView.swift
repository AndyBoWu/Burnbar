import BurnbarCore
import SwiftUI

/// The Settings window: a three-tab `TabView` hosted by the SwiftUI `Settings`
/// scene in `BurnbarApp`. macOS wires this up to the standard `⌘,` menu item,
/// gives it for free a non-modal, single-instance window, and — because the app
/// is an `LSUIElement` agent — closing it leaves the menu-bar status item alive.
///
/// **Scaffold only (1.5.5).** Each tab shows a placeholder heading; the real
/// controls (theme, refresh rate, provider toggles, version/links) land in 1.5.6.
/// Tab identity and labels come from `SettingsTab` in `BurnbarCore`.
struct SettingsView: View {
    /// Selected tab. Kept in `@State` so 1.5.6 can deep-link a tab (e.g. the
    /// popover's "Open Settings" jumping straight to Providers).
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        // A fixed frame keeps the macOS Settings window from resizing as tabs
        // swap; 1.5.6 can revisit once each tab's real content has a height.
        .frame(width: 460, height: 280)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            SettingsPlaceholder(
                title: "General",
                systemImage: "gearshape",
                detail: "Theme and refresh rate settings will live here."
            )
        case .providers:
            SettingsPlaceholder(
                title: "Providers",
                systemImage: "square.stack.3d.up",
                detail: "Enable or disable Claude Code and OpenAI Codex here."
            )
        case .about:
            SettingsPlaceholder(
                title: "About Burnbar",
                systemImage: "flame.fill",
                detail: "\(SettingsTab.aboutVersionLabel) — links and credits coming soon."
            )
        }
    }
}

/// Shared empty-tab scaffold: a centered icon, title, and one line of detail.
/// Replaced tab-by-tab in 1.5.6 as real controls land.
private struct SettingsPlaceholder: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

#Preview {
    SettingsView()
}
