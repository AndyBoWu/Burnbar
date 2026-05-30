import AppKit
import SwiftUI

/// Owns the menu-bar `NSStatusItem` (the `flame.fill` icon) and the popover it
/// presents. Created once at launch by `AppDelegate` and retained for the app
/// lifetime.
///
/// This is Epic 1.5.1: the status item + popover host + refresh plumbing. The
/// popover currently shows the placeholder `BurnbarMenuContent`; real provider
/// tiles and a live burn total in the status-item title arrive in 1.5.2+.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BurnbarMenuContent())

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Burnbar")
            image?.isTemplate = true // adapt to light/dark menu bars
            button.image = image
            button.toolTip = "Burnbar"
            button.target = self
            button.action = #selector(togglePopover)
        }

        // Re-read and refresh whenever usage data changes (posted by the data
        // store in 1.5.2). queue: .main guarantees main-thread delivery. This
        // controller lives for the whole app lifetime, so the observer is never
        // removed; [weak self] avoids a retain cycle in the meantime.
        _ = NotificationCenter.default.addObserver(
            forName: .burnbarDidRefresh,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Show/hide the popover anchored under the status-item button.
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Re-read the latest aggregated total and update the status-item
    /// presentation. For 1.5.1 this refreshes the tooltip; the live burn number
    /// in the title lands with the data store in 1.5.2.
    func refresh() {
        statusItem.button?.toolTip = "Burnbar"
    }
}

extension Notification.Name {
    /// Posted after usage data is re-read so the UI (status item, popover) can
    /// refresh. See `MenuBarController` and the 1.5.2 data store.
    static let burnbarDidRefresh = Notification.Name("xyz.andybowu.Burnbar.didRefresh")
}
