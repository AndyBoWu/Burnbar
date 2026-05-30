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
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store = UsageStore()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(store: store))

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Burnbar")
            image?.isTemplate = true // adapt to light/dark menu bars
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Burnbar"
            button.target = self
            button.action = #selector(togglePopover)
        }

        // Refresh the status-item title whenever a load completes.
        _ = NotificationCenter.default.addObserver(
            forName: .burnbarDidRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        store.refresh()
    }

    /// Show/hide the popover anchored under the status-item button. Opening the
    /// popover triggers a fresh load so the glance is current.
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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

extension Notification.Name {
    /// Posted after usage data is re-read so the UI (status item, popover) can
    /// refresh. See `MenuBarController` and `UsageStore`.
    static let burnbarDidRefresh = Notification.Name("xyz.andybowu.Burnbar.didRefresh")
}
