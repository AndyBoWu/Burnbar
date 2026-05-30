import AppKit
import BurnbarCore
import SwiftUI

/// Burnbar runs as a menu-bar agent (`LSUIElement = YES`, no Dock icon).
///
/// The menu-bar `NSStatusItem` is owned by `MenuBarController`, created by
/// `AppDelegate` at launch (Epic 1.5.1). The SwiftUI `Settings` scene is a
/// placeholder until the real Settings window lands in Epic 1.5.5.
@main
struct BurnbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Creates the menu-bar status item once on launch and pins the app to
/// `.accessory` (belt-and-suspenders with `LSUIElement = YES`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
    }
}
