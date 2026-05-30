import AppKit
import BurnbarCore
import SwiftUI

/// Burnbar runs as a menu-bar agent (`LSUIElement = YES`, no Dock icon).
///
/// The menu-bar `NSStatusItem` is owned by `MenuBarController`, created by
/// `AppDelegate` at launch (Epic 1.5.1). The SwiftUI `Settings` scene hosts the
/// three-tab Settings window (Epic 1.5.5); macOS wires it to `⌘,` and gives it a
/// non-modal, single-instance window whose close leaves the agent running.
@main
struct BurnbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// Creates the menu-bar status item once on launch and pins the app to
/// `.accessory` (belt-and-suspenders with `LSUIElement = YES`).
///
/// Also owns the single ``SyncWriteController`` (2.2.4), which keeps this
/// machine's iCloud rollup fresh on a timer, on system wake, and on quit. It is a
/// standalone background concern, independent of the status item and popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var syncWriteController: SyncWriteController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()

        let syncWriteController = SyncWriteController()
        syncWriteController.start()
        self.syncWriteController = syncWriteController
    }
}
