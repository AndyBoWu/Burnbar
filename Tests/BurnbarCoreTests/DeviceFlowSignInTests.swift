import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises the device-flow sign-in state machine (``DeviceFlowSignIn``) with a
/// fully injected ``GitHubDeviceFlow`` client, an in-memory token sink, and a
/// recording browser opener — so every transition is verified with **no real
/// network, no Keychain, and no browser**.
///
/// Covers the sub-ticket 3.2.2 Definition of Done from the controller's side: the
/// happy path emits `requestingCode → awaitingAuthorization → signedIn`, surfaces
/// a copyable user code, and opens the verification URL; the failure paths
/// (device-code request error, polling denial, and a Keychain save failure) all
/// land in `failed` with a plain-English message.
final class DeviceFlowSignInTests: XCTestCase {

    // MARK: - Recorders

    /// Thread-safe collector of every emitted ``SignInState`` plus the saved token
    /// and opened URLs. `@unchecked Sendable` (guarded by a lock) so it is safe to
    /// capture in the `@Sendable` closures `DeviceFlowSignIn` requires.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var statesStore: [SignInState] = []
        private var savedTokenStore: String?
        private var openedURLsStore: [URL] = []

        func record(_ state: SignInState) {
            lock.lock(); defer { lock.unlock() }
            statesStore.append(state)
        }

        func save(_ token: String) {
            lock.lock(); defer { lock.unlock() }
            savedTokenStore = token
        }

        func open(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            openedURLsStore.append(url)
        }

        var states: [SignInState] {
            lock.lock(); defer { lock.unlock() }
            return statesStore
        }

        var savedToken: String? {
            lock.lock(); defer { lock.unlock() }
            return savedTokenStore
        }

        var openedURLs: [URL] {
            lock.lock(); defer { lock.unlock() }
            return openedURLsStore
        }
    }

    /// A scripted transport for ``GitHubDeviceFlow``: returns queued responses in
    /// order, falling back to the last one once the script runs dry.
    private actor ScriptedTransport {
        private var responses: [GitHubDeviceFlow.Response]
        private let fallback: GitHubDeviceFlow.Response

        init(_ responses: [GitHubDeviceFlow.Response], fallback: GitHubDeviceFlow.Response) {
            self.responses = responses
            self.fallback = fallback
        }

        func next(_: GitHubDeviceFlow.Request) -> GitHubDeviceFlow.Response {
            guard !responses.isEmpty else { return fallback }
            return responses.removeFirst()
        }
    }

    // MARK: - Builders

    private func response(_ json: String, status: Int = 200) -> GitHubDeviceFlow.Response {
        GitHubDeviceFlow.Response(data: Data(json.utf8), status: status)
    }

    private func deviceCodeResponse() -> GitHubDeviceFlow.Response {
        response(#"""
        {"device_code":"dc_123","user_code":"WDJB-MJHT",\#
        "verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """#)
    }

    private func pendingResponse() -> GitHubDeviceFlow.Response {
        response(#"{"error":"authorization_pending","error_description":"pending"}"#)
    }

    private func successResponse() -> GitHubDeviceFlow.Response {
        response(#"{"access_token":"gho_TESTTOKEN","token_type":"bearer","scope":""}"#)
    }

    /// A `GitHubDeviceFlow` wired to a scripted transport, a no-op sleep, and a
    /// real clock (the polls resolve immediately so the 15-minute deadline is
    /// never approached).
    private func flow(responses: [GitHubDeviceFlow.Response]) -> GitHubDeviceFlow {
        let last = responses.last ?? successResponse()
        let transport = ScriptedTransport(responses, fallback: last)
        return GitHubDeviceFlow(
            clientID: "test-client-id",
            transport: { request in await transport.next(request) },
            sleep: { _ in },
            now: { Date() }
        )
    }

    private func makeSignIn(
        deviceFlow: GitHubDeviceFlow,
        recorder: Recorder,
        saveToken: @escaping DeviceFlowSignIn.SaveToken
    ) -> DeviceFlowSignIn {
        DeviceFlowSignIn(
            deviceFlow: deviceFlow,
            saveToken: saveToken,
            openURL: { recorder.open($0) },
            emit: { recorder.record($0) }
        )
    }

    // MARK: - Success path

    func testSuccessPathEmitsStatesOpensURLAndSavesToken() async {
        let recorder = Recorder()
        let signIn = makeSignIn(
            deviceFlow: flow(responses: [deviceCodeResponse(), pendingResponse(), successResponse()]),
            recorder: recorder,
            saveToken: { recorder.save($0) }
        )

        await signIn.run()

        // Transitions: requestingCode -> awaitingAuthorization(code) -> signedIn.
        XCTAssertEqual(recorder.states, [
            .requestingCode,
            .awaitingAuthorization(userCode: "WDJB-MJHT", verificationURI: "https://github.com/login/device"),
            .signedIn
        ])
        // The verification URL was opened in the browser exactly once.
        XCTAssertEqual(recorder.openedURLs, [URL(string: "https://github.com/login/device")!])
        // The granted token was handed to the save closure (the Keychain in prod).
        XCTAssertEqual(recorder.savedToken, "gho_TESTTOKEN")
    }

    /// The awaiting state must carry the user code so the row can show + copy it.
    func testAwaitingStateExposesCopyableUserCode() async {
        let recorder = Recorder()
        let signIn = makeSignIn(
            deviceFlow: flow(responses: [deviceCodeResponse(), successResponse()]),
            recorder: recorder,
            saveToken: { recorder.save($0) }
        )

        await signIn.run()

        let awaiting = recorder.states.first {
            if case .awaitingAuthorization = $0 { return true }
            return false
        }
        guard case let .awaitingAuthorization(userCode, _) = awaiting else {
            return XCTFail("expected an awaitingAuthorization state")
        }
        XCTAssertEqual(userCode, "WDJB-MJHT")
    }

    // MARK: - Failure paths

    func testDeviceCodeRequestFailureEmitsFailedAndNeverOpensBrowser() async {
        let recorder = Recorder()
        // A device-code request that returns an error body -> requestDeviceCode throws.
        let errorBody = response(#"{"error":"server_error","error_description":"GitHub is down"}"#)
        let signIn = makeSignIn(
            deviceFlow: flow(responses: [errorBody]),
            recorder: recorder,
            saveToken: { recorder.save($0) }
        )

        await signIn.run()

        XCTAssertEqual(recorder.states, [
            .requestingCode,
            .failed(message: "GitHub is down")
        ])
        // No code was obtained, so no browser open and no token saved.
        XCTAssertTrue(recorder.openedURLs.isEmpty)
        XCTAssertNil(recorder.savedToken)
    }

    func testAccessDeniedDuringPollingEmitsFailed() async {
        let recorder = Recorder()
        let denied = response(#"{"error":"access_denied","error_description":"denied"}"#)
        let signIn = makeSignIn(
            deviceFlow: flow(responses: [deviceCodeResponse(), denied]),
            recorder: recorder,
            saveToken: { recorder.save($0) }
        )

        await signIn.run()

        // The browser still opened (we surfaced the code) but polling was denied.
        XCTAssertEqual(recorder.openedURLs.count, 1)
        XCTAssertEqual(recorder.states.last, .failed(message: "Authorization was denied. Please try again."))
        XCTAssertNil(recorder.savedToken)
    }

    func testKeychainSaveFailureEmitsFailedNotSignedIn() async {
        struct SaveError: Error {}
        let recorder = Recorder()
        let signIn = makeSignIn(
            deviceFlow: flow(responses: [deviceCodeResponse(), successResponse()]),
            recorder: recorder,
            saveToken: { _ in throw SaveError() }
        )

        await signIn.run()

        // The token came back but persisting it failed: the user must see a
        // failure, never a false "signed in".
        XCTAssertFalse(recorder.states.contains(.signedIn))
        guard case .failed = recorder.states.last else {
            return XCTFail("expected a failed state after a Keychain save error")
        }
    }

    // MARK: - Message mapping

    func testMessageMapsKnownDeviceFlowErrors() {
        XCTAssertEqual(
            DeviceFlowSignIn.message(for: GitHubDeviceFlow.DeviceFlowError.timedOut),
            "Sign-in timed out. Please try again."
        )
        XCTAssertEqual(
            DeviceFlowSignIn.message(for: GitHubDeviceFlow.DeviceFlowError.expiredToken),
            "The code expired before you authorized. Please try again."
        )
        XCTAssertEqual(
            DeviceFlowSignIn.message(for: GitHubDeviceFlow.DeviceFlowError.httpStatus(503)),
            "GitHub returned an unexpected response (HTTP 503). Please try again."
        )
    }
}
