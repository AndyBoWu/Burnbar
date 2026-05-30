import BurnbarCore
import SwiftUI

/// Burnbar runs as a menu-bar agent (`LSUIElement = YES`, no Dock icon).
///
/// M1.1.1 ships only the skeleton: a `flame.fill` status item whose popover
/// shows a placeholder. The real status-item controller (`NSStatusItem` +
/// `MenuBarController`) and provider tiles arrive in Epic 1.5.
@main
struct BurnbarApp: App {
    var body: some Scene {
        MenuBarExtra("Burnbar", systemImage: "flame.fill") {
            BurnbarMenuContent()
        }
        .menuBarExtraStyle(.window)
    }
}
