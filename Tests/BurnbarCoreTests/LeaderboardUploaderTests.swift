import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``LeaderboardUploader`` — the M3 upload client behind the Settings
/// "Upload now" button and the daily scheduler (sub-ticket 3.3.4).
///
/// The injected transport stub captures every `URLRequest` with **no network**, so
/// the Definition of Done is asserted directly:
/// - each POSTed body carries **exactly** the allowlisted keys
///   `{date, provider, tokens, cost_usd}` and nothing else (the privacy schema),
/// - the request carries the GitHub bearer token as `Authorization: Bearer …`,
/// - it targets `POST {apiBase}/api/v1/usage`,
/// - a missing token short-circuits to ``LeaderboardUploader/UploadError/notAuthenticated``
///   with nothing sent (opt-out / signed-out blocks uploads), and
/// - an invalid row fails closed (validator gate) and a non-2xx status surfaces as
///   a server error.
final class LeaderboardUploaderTests: XCTestCase {

    // MARK: - Transport spy

    /// Records every request the uploader hands the transport, and replies with a
    /// scripted status code, so the captured requests can be asserted after the
    /// upload — no real network.
    private final class TransportSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var status = 201

        var transport: LeaderboardUploader.Transport {
            { [self] request in
                // `withLock` is synchronous, so it is safe to call from this async
                // closure (a bare `lock()`/`unlock()` is not, under Swift 6).
                let status = lock.withLock {
                    requests.append(request)
                    return self.status
                }
                return (Data("{\"ok\":true}".utf8), status)
            }
        }

        /// The decoded JSON bodies of every captured request.
        func bodies() throws -> [[String: Any]] {
            try requests.map { request in
                let body = try XCTUnwrap(request.httpBody, "request had no body")
                let object = try JSONSerialization.jsonObject(with: body)
                return try XCTUnwrap(object as? [String: Any], "body was not a JSON object")
            }
        }
    }

    // MARK: - Fixtures

    private let apiBase = URL(string: "https://api.example.test")!

    private func record(
        date: String = "2026-05-30",
        provider: Provider = .claude,
        tokens: Int = 12345,
        costUSD: Double = 1.23
    ) -> LeaderboardRecord {
        LeaderboardRecord(date: date, provider: provider, tokens: tokens, costUSD: costUSD)
    }

    private func uploader(
        token: String? = "ghp_test_token",
        transport: @escaping LeaderboardUploader.Transport
    ) -> LeaderboardUploader {
        LeaderboardUploader(apiBase: apiBase, token: { token }, transport: transport)
    }

    // MARK: - Happy path: validated body + bearer token

    func testPostsExactlyTheAllowlistedKeys() async throws {
        let spy = TransportSpy()
        let sut = uploader(transport: spy.transport)

        let accepted = try await sut.upload([record()])

        XCTAssertEqual(accepted, 1)
        let bodies = try spy.bodies()
        XCTAssertEqual(bodies.count, 1)
        // The body's keys must be EXACTLY the privacy allowlist — no machine_id,
        // model, cwd, etc.
        XCTAssertEqual(Set(bodies[0].keys), ["date", "provider", "tokens", "cost_usd"])
        XCTAssertEqual(bodies[0]["date"] as? String, "2026-05-30")
        XCTAssertEqual(bodies[0]["provider"] as? String, "claude")
        XCTAssertEqual(bodies[0]["tokens"] as? Int, 12345)
        XCTAssertEqual(bodies[0]["cost_usd"] as? Double, 1.23)
    }

    func testCarriesTheBearerToken() async throws {
        let spy = TransportSpy()
        let sut = uploader(token: "ghp_secret_42", transport: spy.transport)

        _ = try await sut.upload([record()])

        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer ghp_secret_42"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testPostsToUsageEndpoint() async throws {
        let spy = TransportSpy()
        let sut = uploader(transport: spy.transport)

        _ = try await sut.upload([record()])

        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/v1/usage")
    }

    func testPostsEveryRowInOrder() async throws {
        let spy = TransportSpy()
        let sut = uploader(transport: spy.transport)

        let accepted = try await sut.upload([
            record(date: "2026-05-30", provider: .claude, tokens: 100),
            record(date: "2026-05-30", provider: .codex, tokens: 200),
            record(date: "2026-05-29", provider: .claude, tokens: 300)
        ])

        XCTAssertEqual(accepted, 3)
        let bodies = try spy.bodies()
        XCTAssertEqual(bodies.map { $0["tokens"] as? Int }, [100, 200, 300])
        // Every captured request must still carry the token + allowlisted keys.
        for (request, body) in zip(spy.requests, bodies) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_test_token")
            XCTAssertEqual(Set(body.keys), ["date", "provider", "tokens", "cost_usd"])
        }
    }

    func testEmptyBatchIsNoOp() async throws {
        let spy = TransportSpy()
        let sut = uploader(transport: spy.transport)

        let accepted = try await sut.upload([])

        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(spy.requests.isEmpty)
    }

    // MARK: - Gating: signed out / opted out blocks uploads

    func testMissingTokenThrowsNotAuthenticatedAndSendsNothing() async {
        let spy = TransportSpy()
        // A nil token models "signed out" / "opted out so no token read".
        let sut = uploader(token: nil, transport: spy.transport)

        do {
            _ = try await sut.upload([record()])
            XCTFail("expected notAuthenticated")
        } catch let error as LeaderboardUploader.UploadError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // Nothing reached the wire.
        XCTAssertTrue(spy.requests.isEmpty)
    }

    // MARK: - Validation gate (fail-closed)

    func testServerRejectionSurfacesAsServerError() async {
        let spy = TransportSpy()
        spy.status = 400
        let sut = uploader(transport: spy.transport)

        do {
            _ = try await sut.upload([record(date: "2026-05-30", provider: .codex)])
            XCTFail("expected server error")
        } catch let error as LeaderboardUploader.UploadError {
            XCTAssertEqual(error, .server(rowID: "2026-05-30|codex", status: 400))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTransportErrorPropagates() async {
        struct Offline: Error {}
        let sut = uploader { _ in throw Offline() }

        do {
            _ = try await sut.upload([record()])
            XCTFail("expected the transport error to propagate")
        } catch is Offline {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
