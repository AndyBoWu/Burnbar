import AppKit
import BurnbarCore
import SwiftUI

/// The Settings window: a three-tab `TabView` hosted by the SwiftUI `Settings`
/// scene in `BurnbarApp`. macOS wires this up to the standard `⌘,` menu item,
/// gives it for free a non-modal, single-instance window, and — because the app
/// is an `LSUIElement` agent — closing it leaves the menu-bar status item alive.
///
/// **Content (1.5.6 / 2.1.3).** Each tab now hosts real, persisted controls:
/// - **General** — theme (auto/light/dark, applied live to `NSApp.appearance`)
///   and the background refresh cadence.
/// - **Providers** — enable/disable Claude and Codex; the flags gate the parsers
///   in `UsageStore` (a disabled provider's tile drops from the popover).
/// - **Devices** — this Mac's `machine_id`, an editable label, and a "Last
///   synced" placeholder row (wired to real timestamps by Epic 2.2).
/// - **About** — app version, GitHub, and privacy links.
///
/// Every control persists via `@AppStorage`/`UserDefaults` (keys in
/// `PreferenceKeys`), so values survive relaunch. English-only literals
/// throughout, per the MVP constraint in CLAUDE.md. Tab identity and labels come
/// from `SettingsTab` in `BurnbarCore`.
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
        // swap; sized to comfortably hold the tallest tab (General).
        .frame(width: 460, height: 300)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView()
        case .providers:
            ProvidersSettingsView()
        case .devices:
            DevicesSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

// MARK: - General

/// Theme + refresh-rate controls. Theme changes apply immediately to the app's
/// `NSApp.appearance`; both selections persist via `@AppStorage`.
private struct GeneralSettingsView: View {
    @AppStorage(PreferenceKeys.theme) private var themeRaw = AppTheme.default.rawValue
    @AppStorage(PreferenceKeys.refreshInterval)
    private var refreshRaw = RefreshInterval.default.rawValue

    private var theme: AppTheme { AppTheme.fromStorage(themeRaw) }

    var body: some View {
        Form {
            Picker("Theme", selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.menu)

            Picker("Refresh rate", selection: $refreshRaw) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval.rawValue)
                }
            }
            .pickerStyle(.menu)

            Text("How often Burnbar re-reads your local Claude and Codex usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        // Apply the persisted theme on appear and whenever it changes, so the
        // choice takes effect live and is restored on relaunch.
        .onAppear { AppearanceController.apply(theme) }
        .onChange(of: themeRaw) { _, _ in
            AppearanceController.apply(theme)
        }
        // A refresh-rate change re-arms the background timer immediately.
        .onChange(of: refreshRaw) { _, _ in
            NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
        }
    }
}

// MARK: - Providers

/// Enable/disable the two — and only two — providers. Toggling a flag posts
/// `.burnbarSettingsDidChange`, which `MenuBarController` turns into a refresh so
/// the popover reflects the new state right away (a disabled provider's tile
/// disappears; re-enabling restores it).
///
/// The hard cap from CLAUDE.md is enforced structurally: there is no affordance
/// to add any provider beyond Claude Code and OpenAI Codex.
private struct ProvidersSettingsView: View {
    @AppStorage(PreferenceKeys.claudeEnabled)
    private var claudeEnabled = PreferenceKeys.providerEnabledByDefault
    @AppStorage(PreferenceKeys.codexEnabled)
    private var codexEnabled = PreferenceKeys.providerEnabledByDefault

    var body: some View {
        Form {
            Section {
                Toggle(Provider.claude.displayName, isOn: $claudeEnabled)
                Toggle(Provider.codex.displayName, isOn: $codexEnabled)
            } footer: {
                Text("Disabling a provider stops Burnbar reading its local logs and removes its tile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: claudeEnabled) { _, _ in notifyChanged() }
        .onChange(of: codexEnabled) { _, _ in notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
    }
}

// MARK: - Devices

/// This Mac's identity row (2.1.3): the opaque `machine_id`, an editable label,
/// and a "Last synced" placeholder.
///
/// - **Machine id** comes from `MachineIdentity.current` — a stable, truncated
///   `SHA-256` digest (16 hex chars). Shown read-only and monospaced.
/// - **Label** is bound to a `MachineLabel` store: typing edits a local `@State`
///   draft and commits to `rename(to:)` on each change, so the override persists
///   to `UserDefaults` and survives relaunch. The placeholder shows the system
///   computer name (the store's default), so clearing the field reverts to it.
/// - **Last synced** is a placeholder ("Never") rendered by
///   `LastSyncedDisplay`; Epic 2.2's WriteController feeds it real timestamps.
///
/// Single-machine scope per #31 — the full multi-machine table is 2.4.4. The
/// store is constructed once on `.standard` defaults; English-only literals
/// throughout, per CLAUDE.md.
private struct DevicesSettingsView: View {
    /// The label store for this Mac (system computer name by default; user
    /// override persisted under `MachineLabel.defaultsKey`).
    private let labelStore = MachineLabel()

    /// This Mac's stable, truncated machine id.
    private let machineID = MachineIdentity.current()

    /// The text being edited, seeded from the persisted label. Kept in `@State`
    /// so the field reflects edits immediately; committed to the store on change.
    @State private var draftLabel = MachineLabel().label

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField(
                        "Name",
                        text: $draftLabel,
                        prompt: Text(MachineLabel.systemComputerName())
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                }

                LabeledContent("Machine ID") {
                    Text(machineID)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Last synced") {
                    Text(LastSyncedDisplay.text(for: nil))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your machine ID is a one-way hash of this Mac's hardware ID — it never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Persist every keystroke through the store so the override survives
        // relaunch and a freshly constructed store sees the same value. An empty
        // field clears the override and reverts to the system name (handled by
        // `MachineLabel.rename`).
        .onChange(of: draftLabel) { _, newValue in
            labelStore.rename(to: newValue)
        }
    }
}

// MARK: - About

/// App version plus GitHub and privacy links, opened in the user's browser via
/// `NSWorkspace.shared.open`.
private struct AboutSettingsView: View {
    /// Burnbar's GitHub repository.
    private static let gitHubURL = URL(string: "https://github.com/AndyBoWu/Burnbar")!
    /// Public privacy statement. The repo README documents Burnbar's privacy
    /// thesis (local logs only; never browser secrets or Keychain).
    private static let privacyURL = URL(
        string: "https://github.com/AndyBoWu/Burnbar#readme"
    )!

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Burnbar")
                .font(.title3.weight(.semibold))
            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 16) {
                Button("GitHub") { open(Self.gitHubURL) }
                Button("Privacy") { open(Self.privacyURL) }
            }
            .padding(.top, 4)

            Text("Burnbar reads only your local Claude Code and Codex usage logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// "Version 0.1.0 (1)" from the app bundle, falling back to
    /// `BurnbarCore.version` if the Info.plist keys are somehow absent.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? BurnbarCore.version
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Applies the user's theme choice to the whole app by setting (or clearing)
/// `NSApp.appearance`. `auto` clears the override so the app follows the system.
@MainActor
enum AppearanceController {
    static func apply(_ theme: AppTheme) {
        switch theme {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

#Preview {
    SettingsView()
}
