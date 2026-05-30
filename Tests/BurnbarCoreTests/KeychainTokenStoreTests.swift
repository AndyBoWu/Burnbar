import XCTest
@testable import BurnbarCore

/// Exercises ``KeychainTokenStore`` against the *real* login Keychain.
///
/// To stay safe and CI-friendly the test uses a throwaway service id
/// (`xyz.andybowu.Burnbar.test-<uuid>`) per run — never the production
/// `github-token` service — and deletes it in `tearDown`. This runs unmodified
/// on a local machine and on the GitHub macOS runner, whose login Keychain is
/// already unlocked for the session.
final class KeychainTokenStoreTests: XCTestCase {
    private var store: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        // Unique throwaway service so parallel/repeated runs never collide and
        // the production token is never touched.
        let service = "xyz.andybowu.Burnbar.test-\(UUID().uuidString)"
        store = KeychainTokenStore(service: service)
    }

    override func tearDown() {
        // Always clean up the throwaway item, even if a test assertion failed.
        try? store?.delete()
        store = nil
        super.tearDown()
    }

    func testFullRoundTrip() throws {
        // read() on an empty service → nil, never an error.
        XCTAssertNil(try store.read(), "fresh service should hold no token")

        // save → read returns exactly what we stored.
        try store.save(token: "ghp_first_token")
        XCTAssertEqual(try store.read(), "ghp_first_token")

        // save again → upsert updates in place (no duplicate item, latest wins).
        try store.save(token: "ghp_second_token")
        XCTAssertEqual(try store.read(), "ghp_second_token")

        // delete → read returns nil again.
        try store.delete()
        XCTAssertNil(try store.read(), "token should be gone after delete")
    }

    func testDeleteOnMissingItemIsNoOp() throws {
        // Deleting when nothing is stored must not throw.
        XCTAssertNoThrow(try store.delete())
        XCTAssertNil(try store.read())
    }

    func testTokenWithUnicodeRoundTrips() throws {
        // UTF-8 round-trip safety for non-ASCII payloads.
        let token = "tok-✓-naïve-😀-\u{1F525}"
        try store.save(token: token)
        XCTAssertEqual(try store.read(), token)
    }

    func testStoresAreIsolatedByService() throws {
        let other = KeychainTokenStore(service: "xyz.andybowu.Burnbar.test-\(UUID().uuidString)")
        defer { try? other.delete() }

        try store.save(token: "in-store")
        // A different service id sees nothing this store wrote.
        XCTAssertNil(try other.read())
        XCTAssertEqual(try store.read(), "in-store")
    }

    func testProductionServiceIdMatchesContract() {
        // Locks the privacy-thesis service id: must stay our own namespace.
        XCTAssertEqual(KeychainTokenStore.defaultService, "xyz.andybowu.Burnbar.github-token")
    }
}
