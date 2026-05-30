import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``AccountDeleter`` — the M3 "delete all my data" client behind the
/// Settings destructive button (sub-ticket 3.5.2).
///
/// The injected transport stub captures every `URLRequest` with **no network**, so
/// the Definition of Done is asserted directly:
/// - it targets `DELETE {apiBase}/api/v1/me`,
/// - it carries the GitHub bearer token as `Authorization: Bearer …`,
/// - it sends **no body** (the server derives the `github_id` from the token, so
///   no identifying field leaves the machine),
/// - a missing token short-circuits to
///   ``AccountDeleter/DeleteError/notAuthenticated`` with nothing sent,
/// - a 2xx (including 204 No Content) returns normally so the caller may tear down
///   local state, and
/// - a 401 surfaces as ``AccountDeleter/DeleteError/unauthorized`` while any other
///   non-2xx surfaces as ``AccountDeleter/DeleteError/server(status:)``, leaving
///   local state intact.
///
/// The local-teardown half (Keychain delete + opt-in reset) is verified against
/// the real Keychain + ``UploadPreferences`` in the final two tests, mirroring the
/// `AuthController.deleteAllData()` sequence: the user can re-join cleanly because
/// nothing local lingers.
final class AccountDeleterTests: XCTestCase {

    // MARK: - Transport spy

    /// Records every request the deleter hands the transport, and replies with a
    /// scripted status code, so the captured request can be asserted after the call
    /// — no real network.
    private final class TransportSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var status = 204

        var transport: AccountDeleter.Transport {
            { [self] request in
                let status = lock.withLock {
                    requests.append(request)
                    return self.status
                }
                return (Data(), status)
            }
        }
    }

    // MARK: - Fixtures

    private let apiBase = URL(string: "https://api.example.test")!

    private func deleter(
        token: String? = "ghp_test_token",
        transport: @escaping AccountDeleter.Transport
    ) -> AccountDeleter {
        AccountDeleter(apiBase: apiBase, token: { token }, transport: transport)
    }

    // MARK: - Request shape

    func testDeleteIssuesBodylessBearerDeleteToTheMeEndpoint() async throws {
        let spy = TransportSpy()
        spy.status = 204
        let sut = deleter(token: "ghp_secret", transport: spy.transport)

        try await sut.deleteAccount()

        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url, URL(string: "https://api.example.test/api/v1/me"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer ghp_secret"
        )
        // No identifying body leaves the machine — the server derives github_id
        // from the token.
        XCTAssertNil(request.httpBody, "the delete request must carry no body")
    }

    func testMeURLIsApiBasePlusMePath() {
        let sut = deleter(transport: TransportSpy().transport)
        XCTAssertEqual(sut.meURL, URL(string: "https://api.example.test/api/v1/me"))
    }

    // MARK: - Auth gating

    func testMissingTokenShortCircuitsWithNoRequest() async {
        let spy = TransportSpy()
        let sut = deleter(token: nil, transport: spy.transport)

        do {
            try await sut.deleteAccount()
            XCTFail("expected notAuthenticated when no token is stored")
        } catch let error as AccountDeleter.DeleteError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("expected DeleteError.notAuthenticated, got \(error)")
        }

        XCTAssertTrue(spy.requests.isEmpty, "no request must be sent when signed out")
    }

    // MARK: - Status handling

    func testSuccess200DoesNotThrow() async throws {
        let spy = TransportSpy()
        spy.status = 200
        let sut = deleter(transport: spy.transport)

        try await sut.deleteAccount()
    }

    func testSuccess204DoesNotThrow() async throws {
        let spy = TransportSpy()
        spy.status = 204
        let sut = deleter(transport: spy.transport)

        try await sut.deleteAccount()
    }

    func testUnauthorized401ThrowsUnauthorized() async {
        let spy = TransportSpy()
        spy.status = 401
        let sut = deleter(transport: spy.transport)

        do {
            try await sut.deleteAccount()
            XCTFail("expected unauthorized on HTTP 401")
        } catch let error as AccountDeleter.DeleteError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected DeleteError.unauthorized, got \(error)")
        }
    }

    func testUnexpectedStatusThrowsServer() async {
        let spy = TransportSpy()
        spy.status = 500
        let sut = deleter(transport: spy.transport)

        do {
            try await sut.deleteAccount()
            XCTFail("expected server error on HTTP 500")
        } catch let error as AccountDeleter.DeleteError {
            XCTAssertEqual(error, .server(status: 500))
        } catch {
            XCTFail("expected DeleteError.server, got \(error)")
        }
    }

    func testTransportErrorPropagates() async {
        struct Offline: Error {}
        let sut = AccountDeleter(
            apiBase: apiBase,
            token: { "ghp" },
            transport: { _ in throw Offline() }
        )

        do {
            try await sut.deleteAccount()
            XCTFail("expected the transport error to propagate")
        } catch is Offline {
            // expected
        } catch {
            XCTFail("expected the injected Offline error, got \(error)")
        }
    }

    // MARK: - Error copy is user-ready

    func testDeleteErrorDescriptionsArePlainEnglish() {
        XCTAssertFalse(AccountDeleter.DeleteError.notAuthenticated.description.isEmpty)
        XCTAssertTrue(AccountDeleter.DeleteError.unauthorized.description.contains("session"))
        XCTAssertTrue(AccountDeleter.DeleteError.server(status: 503).description.contains("503"))
    }

    // MARK: - Local teardown (the controller runs this only on a successful delete)

    /// After a successful server delete, the controller clears the Keychain token —
    /// the 3.5.2 DoD that no stale credential remains so the user can re-join.
    /// Uses a throwaway service id so the production token is never touched.
    func testTeardownLeavesKeychainEmptyThenReJoinSucceeds() throws {
        let service = "xyz.andybowu.Burnbar.test-\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { try? store.delete() }

        try store.save(token: "ghp_joined")
        XCTAssertEqual(try store.read(), "ghp_joined")

        // The deleteAllData() local teardown: clear the stored token.
        try store.delete()
        XCTAssertNil(try store.read(), "Keychain entry must be absent after delete")

        // Re-join: signing in again stores a fresh token with no leftover blocking
        // it (the DoD "user can re-join afterward").
        try store.save(token: "ghp_rejoined")
        XCTAssertEqual(try store.read(), "ghp_rejoined")
    }

    /// The opt-in / timestamp / login reset half of the teardown leaves the
    /// leaderboard preferences at their fresh-install baseline (opt-in OFF), so a
    /// re-join starts clean. Uses a throwaway `UserDefaults` suite.
    func testResetClearsOptInAndLoginToBaseline() throws {
        let suiteName = "xyz.andybowu.Burnbar.test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: UploadPreferences.optedInKey)
        defaults.set(Date(), forKey: UploadPreferences.lastUploadAtKey)
        defaults.set("octocat", forKey: UploadPreferences.githubLoginKey)
        XCTAssertTrue(UploadPreferences.isOptedIn(in: defaults))

        UploadPreferences.reset(in: defaults)

        XCTAssertFalse(
            UploadPreferences.isOptedIn(in: defaults),
            "opt-in must be back to its default-OFF baseline after delete"
        )
        XCTAssertNil(UploadPreferences.lastUploadAt(in: defaults))
        XCTAssertNil(UploadPreferences.githubLogin(in: defaults))
    }
}
