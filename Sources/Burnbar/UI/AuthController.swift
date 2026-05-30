import AppKit
import BurnbarCore
import Foundation
import Observation

/// Drives the leaderboard "Sign in with GitHub" UI in Settings (sub-ticket
/// 3.2.2). The thin, `@MainActor @Observable` shell over the pure
/// `DeviceFlowSignIn` state machine in `BurnbarCore`: it owns the published
/// ``state`` the SwiftUI row binds to, and wires the three real external effects
/// the core driver leaves injectable.
///
/// - The device-flow HTTP client (`GitHubDeviceFlow`, #54) requests the device
///   code and polls for the token.
/// - The granted token is persisted by `KeychainTokenStore` (#55) — Burnbar's
///   only Keychain access, under our own `xyz.andybowu.Burnbar.*` service id.
/// - The verification URL opens in the user's default browser via
///   `NSWorkspace.shared.open` — no embedded web view, so no cookies or
///   third-party secrets are ever read (the privacy thesis, CLAUDE.md M3).
///
/// All of those are injected through the initializer, so production wires the
/// real implementations while the *state transitions* are unit-tested against the
/// pure `DeviceFlowSignIn` in `BurnbarCoreTests` — no network, Keychain, or
/// browser. This object only marshals state onto the main actor and exposes the
/// two view affordances (copy the code, start over).
@MainActor
@Observable
final class AuthController {
    /// The current sign-in state the Settings row renders. Starts ``signedOut``
    /// unless a token is already stored (an existing session restores to
    /// ``signedIn`` on construction).
    private(set) var state: SignInState = .signedOut

    /// Builds the `DeviceFlowSignIn` driver for one sign-in attempt, wired to emit
    /// onto `self` on the main actor. Injected so a test could substitute a fake;
    /// production captures the real device-flow client + token store + browser
    /// opener configured below.
    private let makeFlow: @MainActor (_ emit: @escaping DeviceFlowSignIn.Emit) -> DeviceFlowSignIn

    /// Reads the stored token to determine whether a session already exists.
    private let hasStoredToken: @MainActor () -> Bool

    /// Clears any stored token on sign-out.
    private let clearToken: @MainActor () -> Void

    /// Pasteboard writer for "Copy code"; injected so the copy action is testable
    /// without touching the real `NSPasteboard`.
    private let copyToPasteboard: @MainActor (_ text: String) -> Void

    /// The in-flight sign-in `Task`, kept so a fresh ``signIn()`` (or
    /// ``signOut()``) cancels the previous attempt rather than racing two flows.
    private var task: Task<Void, Never>?

    /// Production initializer: the real device-flow client, Keychain store, and
    /// system browser. The dependencies are injectable for tests; the defaults
    /// here are the live wiring.
    ///
    /// - Parameters:
    ///   - deviceFlow: GitHub device-flow client (#54).
    ///   - tokenStore: Keychain-backed token store (#55).
    ///   - openURL: Opens a URL in the default browser. Defaults to
    ///     `NSWorkspace.shared.open`.
    ///   - copyToPasteboard: Writes text to the general pasteboard. Defaults to a
    ///     real `NSPasteboard` write.
    init(
        deviceFlow: GitHubDeviceFlow = GitHubDeviceFlow(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        openURL: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
        copyToPasteboard: @escaping @MainActor (String) -> Void = AuthController.writeToGeneralPasteboard
    ) {
        makeFlow = { emit in
            DeviceFlowSignIn(
                deviceFlow: deviceFlow,
                saveToken: { try tokenStore.save(token: $0) },
                openURL: openURL,
                emit: emit
            )
        }
        // `read()` returns `nil` when no item exists; `try?` flattens a thrown
        // Keychain error to the same `nil`, so a stored, non-nil token is the
        // single "already signed in" condition.
        hasStoredToken = {
            let stored = try? tokenStore.read()
            return stored.flatMap(\.self) != nil
        }
        clearToken = { try? tokenStore.delete() }
        self.copyToPasteboard = copyToPasteboard

        if hasStoredToken() {
            state = .signedIn
        }
    }

    /// Convenience accessor for the row: the copyable user code while
    /// ``SignInState/awaitingAuthorization(userCode:verificationURI:)``, else `nil`.
    var userCode: String? {
        if case let .awaitingAuthorization(userCode, _) = state { return userCode }
        return nil
    }

    /// Convenience accessor for the row: the verification URL (shown as fallback
    /// text) while awaiting authorization, else `nil`.
    var verificationURI: String? {
        if case let .awaitingAuthorization(_, uri) = state { return uri }
        return nil
    }

    /// Start (or restart) the device-flow sign-in. Cancels any in-flight attempt
    /// first, then drives the pure `DeviceFlowSignIn`, which emits each
    /// ``SignInState`` back onto the main actor.
    func signIn() {
        task?.cancel()
        let flow = makeFlow { [weak self] newState in
            // The core driver may emit from any context; hop to the main actor to
            // mutate the `@Observable` state the view reads.
            Task { @MainActor [weak self] in
                self?.state = newState
            }
        }
        task = Task { await flow.run() }
    }

    /// Copy the current user code to the clipboard so the user can paste it into
    /// GitHub's device page. A no-op when not awaiting authorization.
    func copyUserCode() {
        guard let userCode else { return }
        copyToPasteboard(userCode)
    }

    /// Open the verification URL in the default browser again — for the "Open
    /// GitHub" fallback if the automatic open didn't take. A no-op when not
    /// awaiting authorization or if the URL is malformed.
    func openVerificationURL() {
        guard let verificationURI, let url = URL(string: verificationURI) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Cancel any in-flight attempt, clear the stored token, and return to
    /// ``SignInState/signedOut``.
    func signOut() {
        task?.cancel()
        task = nil
        clearToken()
        state = .signedOut
    }

    /// Real pasteboard write used in production: clear the general pasteboard and
    /// set the string. Isolated to `@MainActor` because `NSPasteboard` is.
    static func writeToGeneralPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
