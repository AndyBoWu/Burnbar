import AppKit
import SwiftUI

/// The one-time, first-launch welcome shown in a popover anchored to the
/// status-item flame (#179). Burnbar is an `LSUIElement` agent with no Dock
/// icon, so a fresh launch is otherwise silent — this cue makes the menu-bar
/// presence obvious and points the user at the flame, the popover, and Settings.
///
/// It is presented once (gated by `PreferenceKeys.firstRunOnboardingShown`) and
/// is fully dismissible: the "Got it" button closes it via the `onDismiss`
/// callback `MenuBarController` supplies. Copy stays compact for the 300px-wide
/// popover and uses plain English literals (no String Catalog), per the MVP
/// constraint in CLAUDE.md.
struct FirstRunOnboardingView: View {
    /// Closes the onboarding popover. Owned by `MenuBarController`.
    let onDismiss: () -> Void
    /// Opens the Settings window, then dismisses. Owned by `MenuBarController`.
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Burnbar is running").font(.headline)
            }

            Text("Burnbar lives in your menu bar — no Dock icon, no window.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                row(
                    icon: "flame.fill",
                    text: "Click the flame icon up top to see today's token burn."
                )
                row(
                    icon: "gearshape",
                    text: "Right-click it (or open Settings) for preferences and quit."
                )
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .labelStyle(.titleOnly)
                .controlSize(.small)

                Spacer()

                Button("Got it") {
                    onDismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
#Preview("First-run onboarding") {
    FirstRunOnboardingView(onDismiss: {}, onOpenSettings: {})
}
#endif
