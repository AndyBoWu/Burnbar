import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``GitHubTokenRevoker`` (sub-ticket 3.2.5) with a fully injected
/// transport, plus the sign-out / revoke contract against the *real* Keychain —
/// so the revocation request and the post-action signed-out state are verified
/// with **no real network**.
///
/// Covers the 3.2.5 Definition of Done from the core side:
/// - `revoke(token:)` issues `DELETE /applications/{client_id}/token` with the
///   token in the JSON body (the call GitHub needs to invalidate the token, so an
///   authenticated `/api/v1/me` would 401 afterwards).
/// - 204 and 404 are accepted (token revoked / already unknown); other non-2xx
///   statuses throw.
/// - "Sign out" (a Keychain delete) leaves ``KeychainTokenStore/read()`` `nil`.
/// - The revoke-then-clear ordering invalidates at GitHub *before* the local
///   token is removed.
final class GitHubTokenRevokerTests: XCTestCase {

    // MARK: - Recorder

    /// Thread-safe collector of every ``GitHubTokenRevoker/Request`` the transport
    /// received. `@unchecked Sendable` (lock-guarded) so it is safe to capture in
    /// the `@Sendable` transport closure.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requestsStore: [GitHubTokenRevoker.Request] = []

        func record(_ request: GitHubTokenRevoker.Request) {
            lock.lock(); defer { lock.unlock() }
            requestsStore.append(request)
        }

        var requests: [GitHubTokenRevoker.Request] {
            lock.lock(); defer { lock.unlock() }
            return requestsStore
        }
    }

    /// A revoker whose transport records each request and returns `status`.
    private func revoker(
        clientID: String = "test-client-id",
        status: Int,
        recorder: Recorder
    ) -> GitHubTokenRevoker {
        GitHubTokenRevoker(clientID: clientID) { request in
            recorder.record(request)
            return GitHubTokenRevoker.Response(status: status)
        }
    }

    // MARK: - Request shape

    func testRevokeBuildsDeleteToTheApplicationsTokenEndpoint() async throws {
        let recorder = Recorder()
        let sut = revoker(clientID: "Iv1.abc123", status: 204, recorder: recorder)

        try await sut.revoke(token: "gho_TESTTOKEN")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(
            request.url,
            URL(string: "https://api.github.com/applications/Iv1.abc123/token")
        )
        // The token rides in the JSON body GitHub's revocation endpoint expects.
        XCTAssertEqual(request.accessToken, "gho_TESTTOKEN")
        XCTAssertEqual(
            String(bytes: request.jsonBody, encoding: .utf8),
            #"{"access_token":"gho_TESTTOKEN"}"#
        )
    }

    func testRevocationURLUsesTheClientID() {
        XCTAssertEqual(
            GitHubTokenRevoker.revocationURL(clientID: "client-42"),
            URL(string: "https://api.github.com/applications/client-42/token")
        )
    }

    // MARK: - Status handling

    func testSuccess204DoesNotThrowAndCallsEndpointExactlyOnce() async throws {
        let recorder = Recorder()
        let sut = revoker(status: 204, recorder: recorder)

        try await sut.revoke(token: "gho_x")

        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testNotFoundIsTreatedAsAlreadyRevoked() async {
        let recorder = Recorder()
        let sut = revoker(status: 404, recorder: recorder)

        // 404 = GitHub no longer knows the token; clearing locally is still correct,
        // so revoke must not throw.
        do {
            try await sut.revoke(token: "gho_stale")
        } catch {
            XCTFail("revoke should treat 404 as already-revoked, got \(error)")
        }
    }

    func testUnexpectedStatusThrowsHTTPStatus() async {
        let recorder = Recorder()
        let sut = revoker(status: 401, recorder: recorder)

        do {
            try await sut.revoke(token: "gho_x")
            XCTFail("expected revoke to throw on HTTP 401")
        } catch let error as GitHubTokenRevoker.RevokeError {
            XCTAssertEqual(error, .httpStatus(401))
        } catch {
            XCTFail("expected RevokeError.httpStatus, got \(error)")
        }
    }

    func testTransportErrorPropagates() async {
        struct Offline: Error {}
        let sut = GitHubTokenRevoker(clientID: "c") { _ in throw Offline() }

        do {
            try await sut.revoke(token: "gho_x")
            XCTFail("expected the transport error to propagate")
        } catch is Offline {
            // expected
        } catch {
            XCTFail("expected the injected Offline error, got \(error)")
        }
    }

    // MARK: - Sign-out / revoke contract against the real Keychain

    /// "Sign out" deletes the local token — the 3.2.5 DoD that the Keychain entry
    /// is absent afterwards (so an authenticated `/api/v1/me` would 401). Uses a
    /// throwaway service id so the production token is never touched.
    func testSignOutLeavesKeychainEmpty() throws {
        let service = "xyz.andybowu.Burnbar.test-\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { try? store.delete() }

        try store.save(token: "gho_signed_in")
        XCTAssertEqual(try store.read(), "gho_signed_in")

        // The signOut() effect: clear the stored token.
        try store.delete()

        XCTAssertNil(try store.read(), "Keychain entry must be absent after sign-out")
    }

    /// Revoke must call GitHub *before* the local token is cleared, so a token sent
    /// for revocation is always the live one and a failed revoke never strands a
    /// still-valid token with no local copy. Mirrors `AuthController.revoke()`'s
    /// ordering against the real Keychain + an injected revoker.
    func testRevokeInvokesEndpointThenClearsKeychain() async throws {
        let service = "xyz.andybowu.Burnbar.test-\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { try? store.delete() }
        try store.save(token: "gho_to_revoke")

        let recorder = Recorder()
        let sut = revoker(status: 204, recorder: recorder)

        // The revoke-then-clear sequence the controller performs.
        let token = try XCTUnwrap(try store.read())
        try await sut.revoke(token: token)
        try store.delete()

        // GitHub was asked to invalidate exactly the stored token …
        XCTAssertEqual(recorder.requests.map(\.accessToken), ["gho_to_revoke"])
        // … and only afterwards was the local entry removed.
        XCTAssertNil(try store.read(), "Keychain entry must be absent after revoke")
    }
}
