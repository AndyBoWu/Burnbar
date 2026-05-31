import Foundation
import ServiceManagement

/// Wraps the modern `SMAppService.mainApp` login-item API (macOS 13+) behind a
/// tiny, observable controller the General settings toggle binds to.
///
/// **Source of truth is the system, not a stored bool.** ``isEnabled`` derives
/// from `SMAppService.mainApp.status == .enabled`, so the toggle reflects the
/// *actual* login-item state — including changes the user makes in System
/// Settings → General → Login Items, which we re-read on every ``refresh()``.
///
/// ``setEnabled(_:)`` calls `register()`/`unregister()` (both `throws`). On
/// failure it does **not** crash: it captures a plain-English ``errorMessage``
/// and resyncs ``isEnabled`` to the real `.status`, so the bound toggle snaps
/// back to the truth.
///
/// Registration only fully takes effect from an installed, signed app bundle —
/// `SMAppService` keys the login item off the bundle's code signature and
/// location. From a DerivedData build the calls compile and run but may not
/// persist a login item; that's expected and handled gracefully here.
///
/// English-only literals throughout, per the MVP constraint in CLAUDE.md.
@MainActor
final class LoginItemController: ObservableObject {
    /// Whether Burnbar is currently registered to open at login. Mirrors
    /// `SMAppService.mainApp.status == .enabled`; the view's `Toggle` binds to a
    /// derived binding so flipping it routes through ``setEnabled(_:)``.
    @Published private(set) var isEnabled: Bool

    /// A subtle inline message shown when a register/unregister attempt fails.
    /// `nil` whenever the last operation succeeded.
    @Published private(set) var errorMessage: String?

    /// The system service backing the app's login item. Stored so the same handle
    /// is queried and mutated.
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        isEnabled = service.status == .enabled
    }

    /// Re-read the live `.status` from the system. Call on appear so a change made
    /// in System Settings while Burnbar was running is reflected without a
    /// relaunch. Reading agrees with `.status` again, so any stale error clears.
    func refresh() {
        isEnabled = service.status == .enabled
        errorMessage = nil
    }

    /// Enable or disable opening at login. Routes to `register()`/`unregister()`,
    /// then resyncs ``isEnabled`` to the real `.status` regardless of outcome, so
    /// the toggle always reflects the truth. On failure, surfaces a plain-English
    /// ``errorMessage`` instead of crashing.
    func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try service.register()
            } else {
                // The synchronous `unregister()` removes the login item; the async
                // overload is for the legacy SMLoginItem migration path, unused here.
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = enable
                ? "Couldn't turn on Open at Login. \(error.localizedDescription)"
                : "Couldn't turn off Open at Login. \(error.localizedDescription)"
        }
        // Always resync to the system's view: on success this confirms the new
        // state; on failure it reverts the toggle to what actually happened.
        isEnabled = service.status == .enabled
    }
}
