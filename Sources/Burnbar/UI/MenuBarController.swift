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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(store: store))

        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Burnbar")
            image?.isTemplate = true // adapt to light/dark menu bars
            button.image = image
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
