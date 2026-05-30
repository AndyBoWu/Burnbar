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

/// This Mac's identity row (2.1.3 / 2.5.2): the opaque `machine_id`, an editable
/// label, the live "Last sync …" status, and a stale-sync warning.
///
/// - **Machine id** comes from `MachineIdentity.current` — a stable, truncated
///   `SHA-256` digest (16 hex chars). Shown read-only and monospaced.
/// - **Label** is bound to a `MachineLabel` store: typing edits a local `@State`
///   draft and commits to `rename(to:)` on each change, so the override persists
///   to `UserDefaults` and survives relaunch. The placeholder shows the system
///   computer name (the store's default), so clearing the field reverts to it.
/// - **Last sync** shows the live relative time of this Mac's last successful
///   iCloud rollup write (`SyncWriteSchedule.lastWriteAtKey`, written by 2.2.4),
///   rendered by `LastSyncedDisplay` via the `SyncHealth` verdict.
/// - **Warning row** (2.5.2) appears only when `SyncHealth` is `.stale` — the
///   last write is older than 30 minutes or iCloud Drive is unavailable — and
///   clears automatically on the next successful resync.
///
/// The verdict lives in the `SyncHealthMonitor` view-model (`@Published`), which
/// recomputes on appear, on `.burnbarSettingsDidChange` (the same signal the
/// write scheduler/Settings already broadcast), and on a coarse poll so the
/// relative text and warning stay current without a restart.
///
/// The full multi-machine table (2.4.4) sits below this Mac's identity row: every
/// known machine with its label, truncated id, today / total burn, and last sync,
/// plus the rename / hide / forget row actions. The store is constructed once on
/// `.standard` defaults; English-only literals throughout, per CLAUDE.md.
private struct DevicesSettingsView: View {
    /// The label store for this Mac (system computer name by default; user
    /// override persisted under `MachineLabel.defaultsKey`).
    private let labelStore = MachineLabel()

    /// This Mac's stable, truncated machine id.
    private let machineID = MachineIdentity.current()

    /// The text being edited, seeded from the persisted label. Kept in `@State`
    /// so the field reflects edits immediately; committed to the store on change.
    @State private var draftLabel = MachineLabel().label

    /// Live sync-freshness verdict, recomputed from the real `last-write-at`
    /// timestamp + iCloud availability (2.5.2).
    @StateObject private var monitor = SyncHealthMonitor()

    /// Backs the full table: loads every machine's rollup + computes per-machine
    /// burn off the main actor, owns rename/hide/forget (2.4.4).
    @State private var fleet = DevicesViewModel()

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

                LabeledContent("Last sync") {
                    Text(monitor.health.statusLabel)
                        .foregroundStyle(.secondary)
                }

                if let warning = monitor.health.warningLabel {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your machine ID is a one-way hash of this Mac's hardware ID — it never leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DevicesTableSection(fleet: fleet)
        }
        .formStyle(.grouped)
        // Persist every keystroke through the store so the override survives
        // relaunch and a freshly constructed store sees the same value. An empty
        // field clears the override and reverts to the system name (handled by
        // `MachineLabel.rename`). The fleet table reloads so this Mac's row picks
        // up the new label.
        .onChange(of: draftLabel) { _, newValue in
            labelStore.rename(to: newValue)
            fleet.refresh()
        }
        .onAppear {
            monitor.start()
            fleet.refresh()
        }
        .onDisappear { monitor.stop() }
    }
}

/// The "Devices" section of the Devices tab: the full machine table (2.4.4).
///
/// One row per known machine, each showing the editable label, truncated id,
/// today + total burn, and last-sync relative time, with rename / hide / forget
/// actions in a trailing menu. Renders for one to five machines; an empty fleet or
/// an iCloud-unavailable read shows an explanatory row rather than a blank table.
private struct DevicesTableSection: View {
    @Bindable var fleet: DevicesViewModel

    /// The machine pending a forget confirmation, or `nil` when no dialog is up.
    @State private var pendingForget: DeviceSummary?

    var body: some View {
        Section {
            if let warning = fleet.warning {
                Label(warning, systemImage: "icloud.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if fleet.devices.isEmpty {
                Text(fleet.isLoading ? "Loading devices…" : "No devices yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fleet.devices) { device in
                    DeviceRowView(
                        device: device,
                        rename: { fleet.rename(device.id, to: $0) },
                        toggleHidden: { fleet.toggleHidden(device.id) },
                        forget: { pendingForget = device }
                    )
                }
            }

            // Force resync (2.5.3): write this Mac's rollup now, then re-read every
            // machine and the combined view — without waiting for the next
            // scheduled write. Disabled + spinner-labelled while in flight so a
            // double-tap can't launch two writes.
            HStack(spacing: 8) {
                Button("Force resync") { fleet.forceResync() }
                    .disabled(fleet.isResyncing)
                if fleet.isResyncing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            Text(
                "Each Mac syncs its own usage file. Hiding excludes a device from your combined total; "
                    + "forgetting deletes its synced file."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // Forget is destructive (deletes the synced rollup file), so it is gated
        // behind an explicit confirmation per the 2.4.4 Definition of Done.
        .confirmationDialog(
            "Forget this device?",
            isPresented: forgetDialogBinding,
            presenting: pendingForget
        ) { device in
            Button("Forget \(device.label)", role: .destructive) {
                fleet.forget(device.id)
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: { device in
            Text(forgetMessage(for: device))
        }
    }

    /// Drives the confirmation dialog from the optional `pendingForget`.
    private var forgetDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingForget != nil },
            set: { presented in if !presented { pendingForget = nil } }
        )
    }

    private func forgetMessage(for device: DeviceSummary) -> String {
        if device.isThisMac {
            return "This deletes this Mac's synced usage file. It will be recreated on the next sync."
        }
        return "This deletes \(device.label)'s synced usage file from iCloud Drive. This can't be undone."
    }
}

/// A single machine row: name (inline-editable), truncated id, today / total burn,
/// last sync, and the rename / hide / forget action menu.
private struct DeviceRowView: View {
    let device: DeviceSummary
    let rename: (String) -> Void
    let toggleHidden: () -> Void
    let forget: () -> Void

    /// The label being edited inline, seeded from the device's current label and
    /// committed on submit / focus loss.
    @State private var draftLabel: String

    init(
        device: DeviceSummary,
        rename: @escaping (String) -> Void,
        toggleHidden: @escaping () -> Void,
        forget: @escaping () -> Void
    ) {
        self.device = device
        self.rename = rename
        self.toggleHidden = toggleHidden
        self.forget = forget
        _draftLabel = State(initialValue: device.label)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Name", text: $draftLabel)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 150, alignment: .leading)
                        .onSubmit { rename(draftLabel) }
                    if device.isThisMac {
                        Text("This Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if device.isHidden {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(device.shortID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(burnText(tokens: device.todayTokens, cost: device.todayCostUSD))
                    .font(.callout)
                    .monospacedDigit()
                Text("Total \(burnText(tokens: device.totalTokens, cost: device.totalCostUSD))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("Synced \(lastSyncText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button(device.isHidden ? "Unhide" : "Hide", action: toggleHidden)
                Button("Forget…", role: .destructive, action: forget)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .opacity(device.isHidden ? 0.55 : 1)
        // Re-seed the inline field when the row's label changes underneath us
        // (e.g. a reload after a rename elsewhere).
        .onChange(of: device.label) { _, newValue in
            draftLabel = newValue
        }
    }

    /// "12,345 tok · $0.42" — tokens grouped with thousands separators and the
    /// cost to cents. Privacy-safe aggregate only.
    private func burnText(tokens: Int, cost: Double) -> String {
        "\(tokens.formatted(.number.grouping(.automatic))) tok · \(cost.formatted(.currency(code: "USD")))"
    }

    /// Relative "N days ago" from the machine's latest record day, or "never" when
    /// it has no records.
    private var lastSyncText: String {
        guard let day = device.lastRecordDay,
              let date = Self.dayFormatter.date(from: day)
        else {
            return "never"
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Parses `YYYY-MM-DD` record days as UTC midnight, matching how they're
    /// produced.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Live, observable source of this Mac's ``SyncHealth`` for the Devices tab
/// (2.5.2).
///
/// Reads the `last-write-at` timestamp the write scheduler (2.2.4) persists under
/// `SyncWriteSchedule.lastWriteAtKey` and resolves whether iCloud Drive is
/// currently reachable, then publishes the pure ``SyncHealth`` verdict so the
/// SwiftUI row updates without a restart. The threshold + warning copy live in
/// `BurnbarCore`; this object only handles the (main-actor) recompute triggers:
/// on `start()`, on `.burnbarSettingsDidChange` (broadcast after Settings
/// changes and write attempts), and on a coarse 60-second poll so the relative
/// "N minutes ago" text and the warning stay current.
///
/// iCloud resolution can block, so it runs off the main thread; the published
/// update hops back to the main actor.
@MainActor
private final class SyncHealthMonitor: ObservableObject {
    /// The latest verdict. `@Published` so the view re-renders on every change.
    @Published private(set) var health: SyncHealth

    /// Reads the `last-write-at` slot the scheduler writes.
    private let store = UserDefaultsLastWriteStore()
    /// Resolves the iCloud `Burnbar/` directory to learn availability.
    private let container = ICloudContainer()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// Coarse poll so the relative text advances and the warning appears once the
    /// 30-minute threshold elapses, even with no other trigger.
    private static let pollInterval: TimeInterval = 60

    init() {
        // Seed assuming iCloud is reachable; the first off-main resolve corrects
        // it. Keeps the row populated immediately without blocking the main
        // thread on construction.
        health = SyncHealth.evaluate(
            lastWriteAt: store.lastWriteAt(),
            iCloudAvailable: true
        )
    }

    /// Begin observing: install the poll timer + the settings-changed observer
    /// and refresh once immediately.
    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observer = NotificationCenter.default.addObserver(
            forName: .burnbarSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    /// Tear down the timer + observer when the tab disappears. Paired with
    /// `start()` from the view's `.onAppear`/`.onDisappear`, this is the sole
    /// teardown path: a `nonisolated deinit` cannot touch these `@MainActor`,
    /// non-`Sendable` members under Swift 6 strict concurrency.
    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Resolve iCloud availability off the main thread, then publish a fresh
    /// verdict on the main actor.
    private func refresh() {
        let lastWriteAt = store.lastWriteAt()
        let container = container
        Task { [weak self] in
            let available = await Task.detached { container.resolve().isAvailable }.value
            await MainActor.run {
                self?.health = SyncHealth.evaluate(
                    lastWriteAt: lastWriteAt,
                    iCloudAvailable: available
                )
            }
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
