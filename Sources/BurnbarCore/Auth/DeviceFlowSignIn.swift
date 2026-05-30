import Foundation

/// The observable state of the leaderboard sign-in flow (sub-ticket 3.2.2).
///
/// This is the pure, view-agnostic state machine the SwiftUI `AuthController`
/// publishes. Living in `BurnbarCore` (rather than the app target) keeps every
/// transition unit-testable with **no real network, no real Keychain, and no
/// browser** — the app-side controller is then a thin `@Observable` shell that
/// just mirrors these states and wires the real dependencies.
///
/// The happy path is `signedOut → requestingCode → awaitingAuthorization → …`.
/// Polling for the token (3.2.3) and persisting it to the Keychain (3.2.4) are
/// driven by ``DeviceFlowSignIn`` and land in either ``signedIn`` or
/// ``failed(message:)`` — every terminal/intermediate state carries exactly the
/// data the row needs (the copyable user code + verification URL while waiting, a
/// plain-English message on failure). English-only literals throughout, per the
/// MVP constraint in CLAUDE.md.
public enum SignInState: Equatable, Sendable {
    /// No sign-in in progress and no token stored. The initial state, and the
    /// state after ``DeviceFlowSignIn/signOut()``.
    case signedOut

    /// The device-code `POST` is in flight (phase 1). A brief, non-interactive
    /// "Contacting GitHub…" state.
    case requestingCode

    /// GitHub returned a device code: show the user the copyable ``userCode`` and
    /// the ``verificationURI`` (the browser is opened to it automatically), then
    /// poll until they authorize. This is the only interactive waiting state.
    case awaitingAuthorization(userCode: String, verificationURI: String)

    /// The user authorized and the access token was saved to the Keychain. The
    /// terminal success state.
    case signedIn

    /// The flow failed (network/GitHub error, the user denied access, the code
    /// expired, the 15-minute budget elapsed, or the Keychain write failed). The
    /// associated plain-English ``message`` is shown to the user, who can retry.
    case failed(message: String)
}

/// Drives GitHub's device-flow sign-in for the leaderboard, end to end: request a
/// device code, surface it (and open the browser) for the user, poll for the
/// access token, and hand the token to the Keychain — emitting a ``SignInState``
/// at every step.
///
/// ## Why this lives in `BurnbarCore`
/// All three external effects are injected, so the whole state machine runs in a
/// unit test with no network, no Keychain, and no `NSWorkspace`:
/// - `deviceFlow` — the ``GitHubDeviceFlow`` client (itself fully injectable, so a
///   test can script the two phases without real HTTP).
/// - `saveToken` — persists the access token; production wires `KeychainTokenStore`.
/// - `openURL` — opens the verification page; production wires `NSWorkspace`.
/// - `emit` — receives each new ``SignInState``; the `AuthController` assigns it to
///   its `@Observable` property on the main actor.
///
/// ## Privacy (CLAUDE.md, M3)
/// The access token is handed straight to `saveToken` and never logged, returned,
/// or otherwise retained here. No browser cookies, no third-party Keychain items —
/// authorization happens entirely in the user's own system browser.
///
/// Holds only immutable `@Sendable` closures and value config, so it is
/// `Sendable` and safe to drive from any concurrency domain.
public struct DeviceFlowSignIn: Sendable {

    /// Persists the granted access token (production: `KeychainTokenStore.save`).
    /// Throwing surfaces as a ``SignInState/failed(message:)`` so a Keychain
    /// failure is visible rather than a silent "signed in" with no stored token.
    public typealias SaveToken = @Sendable (_ token: String) throws -> Void

    /// Opens the verification URL in the user's default browser (production:
    /// `NSWorkspace.shared.open`). No embedded web view — authorization stays in
    /// the system browser, per the ticket's privacy note.
    public typealias OpenURL = @Sendable (_ url: URL) -> Void

    /// Receives each new ``SignInState``. The `AuthController` hops it to the main
    /// actor and assigns its published property.
    public typealias Emit = @Sendable (_ state: SignInState) -> Void

    private let deviceFlow: GitHubDeviceFlow
    private let saveToken: SaveToken
    private let openURL: OpenURL
    private let emit: Emit

    /// - Parameters:
    ///   - deviceFlow: The device-flow HTTP client. Defaults to a production
    ///     ``GitHubDeviceFlow`` (real `URLSession` transport).
    ///   - saveToken: Persists the access token on success.
    ///   - openURL: Opens the verification URL in the system browser.
    ///   - emit: Sink for each emitted ``SignInState``.
    public init(
        deviceFlow: GitHubDeviceFlow = GitHubDeviceFlow(),
        saveToken: @escaping SaveToken,
        openURL: @escaping OpenURL,
        emit: @escaping Emit
    ) {
        self.deviceFlow = deviceFlow
        self.saveToken = saveToken
        self.openURL = openURL
        self.emit = emit
    }

    /// Run the full sign-in flow, emitting a ``SignInState`` at every step:
    /// `requestingCode → awaitingAuthorization → signedIn` on success, or
    /// `… → failed(message:)` on any error.
    ///
    /// Concretely:
    /// 1. Emit ``SignInState/requestingCode`` and `POST` for a device code.
    /// 2. On success, emit ``SignInState/awaitingAuthorization(userCode:verificationURI:)``
    ///    — exposing the copyable code — and open the verification URL in the
    ///    browser.
    /// 3. Poll until the user authorizes, then save the token via `saveToken` and
    ///    emit ``SignInState/signedIn``.
    ///
    /// Any thrown error (device-code request, polling, or the Keychain write) is
    /// mapped to a plain-English ``SignInState/failed(message:)`` via
    /// ``message(for:)`` — the flow never throws to its caller, so the
    /// `AuthController`'s `Task` can be fire-and-forget.
    public func run() async {
        emit(.requestingCode)

        let code: GitHubDeviceFlow.DeviceCode
        do {
            code = try await deviceFlow.requestDeviceCode()
        } catch {
            emit(.failed(message: Self.message(for: error)))
            return
        }

        emit(.awaitingAuthorization(userCode: code.userCode, verificationURI: code.verificationURI))
        if let url = URL(string: code.verificationURI) {
            openURL(url)
        }

        do {
            let token = try await deviceFlow.pollForToken(
                deviceCode: code.deviceCode,
                interval: code.interval
            )
            try saveToken(token.accessToken)
            emit(.signedIn)
        } catch {
            emit(.failed(message: Self.message(for: error)))
        }
    }

    /// Map any error thrown during the flow to a short, plain-English message for
    /// the user. Recognised device-flow errors get specific copy; everything else
    /// (including a thrown Keychain error) falls back to its `localizedDescription`.
    static func message(for error: Error) -> String {
        guard let flowError = error as? GitHubDeviceFlow.DeviceFlowError else {
            return error.localizedDescription
        }
        switch flowError {
        case .timedOut:
            return "Sign-in timed out. Please try again."
        case .accessDenied:
            return "Authorization was denied. Please try again."
        case .expiredToken:
            return "The code expired before you authorized. Please try again."
        case let .httpStatus(status):
            return "GitHub returned an unexpected response (HTTP \(status)). Please try again."
        case .decoding:
            return "Couldn't read GitHub's response. Please try again."
        case let .server(error, description):
            return description ?? "GitHub reported an error: \(error)."
        }
    }
}
