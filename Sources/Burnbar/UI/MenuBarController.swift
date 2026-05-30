import AppKit
import BurnbarCore
import SwiftUI

/// Owns the menu-bar `NSStatusItem` (the `flame.fill` icon) and the popover it
/// presents. Created once at launch by `AppDelegate` and retained for the app
/// lifetime.
///
/// The status-item title shows today's total spend; the popover (1.5.2) shows a
/// `ProviderTileView` per provider. Data comes from `UsageStore`, refreshed on
/// launch and whenever the popover opens.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store = UsageStore()
    /// Background refresh timer, re-armed from the persisted refresh rate (1.5.6)
    /// on launch and whenever the setting changes.
    private var refreshTimer: Timer?

    /// Resolves the iCloud `Burnbar/` directory. `resolve()` can block (ubiquity
    /// lookup), so it is always called off the main thread (2.5.1).
    private let iCloudContainer = ICloudContainer()
    /// Re-checks iCloud availability on a short cadence so the badge appears /
    /// clears within a few seconds of the user toggling iCloud Drive (2.5.1).
    private var iCloudCheckTimer: Timer?
    /// Last applied badge state; skips redundant icon/tooltip work each tick.
    private var iCloudBadge: ICloudBadgeState = .ok

    /// Cached `flame.fill` images so the per-tick availability check never
    /// re-renders. `plainIcon` is the normal template flame; `warningIcon` is the
    /// flame with a small `exclamationmark.triangle.fill` composited bottom-right.
    private let plainIcon = MenuBarController.makePlainIcon()
    private let warningIcon = MenuBarController.makeWarningIcon()

    /// How often to re-resolve iCloud availability (2.5.1). 30s keeps the badge
    /// responsive without measurable cost; wake + identity-change notifications
    /// cover the fast-path cases between ticks.
    private static let iCloudCheckInterval: TimeInterval = 30

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(store: store))

        super.init()

        if let button = statusItem.button {
            button.image = plainIcon
            button.imagePosition = .imageLeading
            button.toolTip = "Burnbar"
            button.target = self
            button.action = #selector(handleClick)
            // Left-click toggles the popover; right-click shows the context menu.
            // Routing both buttons through one action lets us branch on the event
            // type without assigning `statusItem.menu` (which would steal the
            // left-click and pop the menu on every press).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Refresh the status-item title whenever a load completes.
        _ = NotificationCenter.default.addObserver(
            forName: .burnbarDidRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // A Settings change (provider toggle / refresh rate) re-reads usage and
        // re-arms the background timer so the popover reflects it immediately.
        _ = NotificationCenter.default.addObserver(
            forName: .burnbarSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.store.refresh()
                self?.rearmRefreshTimer()
            }
        }

        // Apply the persisted theme on launch so the menu bar / popover / Settings
        // window honor the user's last choice before any window is shown.
        AppearanceController.apply(AppTheme.fromStorage(UserDefaults.standard.string(forKey: PreferenceKeys.theme)))

        store.refresh()
        rearmRefreshTimer()
        startICloudMonitoring()
    }

    /// Re-create the background refresh timer from the persisted refresh rate.
    /// Invalidates any prior timer first so the cadence change takes effect at
    /// once rather than on the next tick.
    private func rearmRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = RefreshInterval.fromStorage(
            UserDefaults.standard.string(forKey: PreferenceKeys.refreshInterval)
        )
        let timer = Timer(timeInterval: interval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        // Common run-loop mode so the timer still fires while a menu/popover is up.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - iCloud availability badge (2.5.1)

    /// Begin watching iCloud availability: an immediate check, a ~30s repeating
    /// timer, plus system-wake and iCloud-identity-change notifications. Each
    /// trigger resolves the container **off** the main thread and applies the
    /// resulting badge state back on the main actor, so the warning overlay +
    /// tooltip appear within a few seconds of iCloud Drive being disabled and
    /// clear when it is re-enabled.
    private func startICloudMonitoring() {
        let timer = Timer(timeInterval: Self.iCloudCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkICloudAvailability() }
        }
        // Common mode so the check keeps firing while a menu/popover is up.
        RunLoop.main.add(timer, forMode: .common)
        iCloudCheckTimer = timer

        // Re-check promptly when the Mac wakes (iCloud may have changed while
        // asleep) and whenever the iCloud account/identity changes. The
        // controller lives for the whole app lifetime, so the observer tokens
        // are discarded like the other lifetime observers in `init`.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkICloudAvailability() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkICloudAvailability() }
        }

        checkICloudAvailability()
    }

    /// Resolve iCloud availability off the main thread, then hop back to apply
    /// the badge. `resolve()` can block on the ubiquity lookup, so it must never
    /// run on the main actor.
    private func checkICloudAvailability() {
        let container = iCloudContainer
        Task.detached {
            let location = container.resolve()
            let state = ICloudBadgeState(location: location)
            await MainActor.run { [weak self] in
                self?.applyICloudBadge(state)
            }
        }
    }

    /// Apply the resolved badge state to the status-item button: swap to the
    /// warning icon + warning tooltip when disabled, restore the plain icon and
    /// the normal cost-title/tooltip when available. Idempotent — repeated calls
    /// with the same state do no work, so the 30s cadence is free of redraw cost.
    private func applyICloudBadge(_ state: ICloudBadgeState) {
        guard state != iCloudBadge else { return }
        iCloudBadge = state
        guard let button = statusItem.button else { return }

        button.image = state.showsWarning ? warningIcon : plainIcon
        if state.showsWarning {
            button.toolTip = state.tooltip
        } else {
            // Restore whatever the cost title would set (today's spend or the
            // plain "Burnbar" tooltip). `refresh()` owns that copy.
            refresh()
        }
    }

    // MARK: - Status-item icons

    /// The normal template `flame.fill` icon used in the menu bar.
    private static func makePlainIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Burnbar")
        image?.isTemplate = true // adapt to light/dark menu bars
        return image
    }

    /// The `flame.fill` icon with a small `exclamationmark.triangle.fill`
    /// composited into the bottom-right corner, used while iCloud is disabled
    /// (2.5.1). Rendered once and cached; not a template image because the
    /// warning glyph reads best in its own tint.
    private static func makeWarningIcon() -> NSImage? {
        guard
            let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil),
            let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        else {
            return makePlainIcon()
        }

        // Match the menu bar's ~18pt content height.
        let side: CGFloat = 18
        let badgeSide = side * 0.62
        let composed = NSImage(size: NSSize(width: side, height: side))

        composed.lockFocus()
        flame.isTemplate = true
        flame.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        // Bottom-right corner overlay.
        warning.draw(
            in: NSRect(x: side - badgeSide, y: 0, width: badgeSide, height: badgeSide),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        composed.unlockFocus()

        composed.accessibilityDescription = ICloudBadgeState.warning.accessibilityDescription
        return composed
    }

    /// Routes a status-item click: right-click (or control-click) shows the
    /// context menu; any other click toggles the popover. Left-click behavior is
    /// unchanged from 1.5.1.
    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// Show/hide the popover anchored under the status-item button. Opening the
    /// popover triggers a fresh load so the glance is current.
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Present the right-click context menu under the status item with the same
    /// three quick actions as the popover footer (1.5.4): Refresh now, Settings…,
    /// Quit. The menu is built fresh and assigned only for this click, then
    /// cleared in `menuDidClose` so it never hijacks a left-click.
    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.delegate = self

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Burnbar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    // MARK: - Quick actions (shared by the popover footer and the context menu)

    @objc private func refreshNow() {
        store.refresh()
    }

    @objc private func openSettings() {
        MenuActions.openSettings()
    }

    @objc private func quit() {
        MenuActions.quit()
    }

    /// Update the status-item title from the latest load: today's total spend
    /// next to the flame (empty until the first load completes).
    func refresh() {
        guard let button = statusItem.button else { return }
        if let today = store.today, today.costUSD > 0 {
            button.title = " " + BurnFormat.cost(today.costUSD)
            button.toolTip = "Burnbar — \(BurnFormat.cost(today.costUSD)) today"
        } else {
            button.title = ""
            button.toolTip = "Burnbar"
        }
        // The iCloud warning tooltip outranks the cost tooltip: when sync is off,
        // keep the explanatory copy so refreshes don't silently clear it (2.5.1).
        if let warningTooltip = iCloudBadge.tooltip {
            button.toolTip = warningTooltip
        }
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Clear the status item's menu once the context menu closes so the next
    /// left-click toggles the popover instead of reopening the menu.
    nonisolated func menuDidClose(_: NSMenu) {
        MainActor.assumeIsolated {
            statusItem.menu = nil
        }
    }
}

/// Quick actions shared by the popover footer (SwiftUI) and the status-item
/// context menu (AppKit), so both reach the same behavior in one place.
@MainActor
enum MenuActions {
    /// Open the SwiftUI `Settings` scene declared in `BurnbarApp`. macOS 14
    /// renamed the private selector to `showSettingsWindow:`; sending it to the
    /// responder chain (`to: nil`) routes it to the `Settings` scene.
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Terminate the agent cleanly.
    static func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    /// Posted after usage data is re-read so the UI (status item, popover) can
    /// refresh. See `MenuBarController` and `UsageStore`.
    static let burnbarDidRefresh = Notification.Name("xyz.andybowu.Burnbar.didRefresh")

    /// Posted when a Settings control changes that affects loading (provider
    /// toggles, refresh rate). `MenuBarController` re-reads usage and re-arms the
    /// background refresh timer so the popover reflects the new state at once.
    static let burnbarSettingsDidChange = Notification.Name("xyz.andybowu.Burnbar.settingsDidChange")
}
