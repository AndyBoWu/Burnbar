import Foundation

/// Revokes a GitHub OAuth access token at GitHub for Burnbar's M3 leaderboard
/// sign-out (sub-ticket 3.2.5).
///
/// "Sign out" alone just deletes Burnbar's local Keychain token, leaving the
/// grant live on GitHub's side. "Revoke access" goes further: it asks GitHub to
/// invalidate the token entirely via
/// `DELETE https://api.github.com/applications/{client_id}/token` with the token
/// in the JSON body — so an authenticated `GET /api/v1/me` afterwards returns
/// 401 — **before** the caller clears the local Keychain entry.
///
/// ## Testability
/// The single HTTP round-trip is injected as ``Transport``, so the request this
/// type builds (method, URL, body) is fully unit-testable with **no real
/// network**: a test scripts the transport, runs ``revoke(token:)``, and asserts
/// the recorded ``Request``. Production wires ``urlSessionTransport``.
///
/// ## Privacy (CLAUDE.md, M3)
/// The token to revoke is sent only to GitHub's own API host and is never logged,
/// persisted, or retained here. No browser cookies, no third-party Keychain
/// items. Only Burnbar's own `xyz.andybowu.Burnbar.*` Keychain entry — cleared by
/// the caller after this returns — is ever touched locally.
///
/// Holds only immutable `@Sendable` closures and value config, so it is
/// `Sendable` and safe to share across concurrency domains.
public struct GitHubTokenRevoker: Sendable {

    // MARK: - Endpoint

    /// GitHub's API host that serves the app-token revocation endpoint.
    public static let apiBaseURL = URL(string: "https://api.github.com")!

    /// Build the `DELETE` target for `clientID`:
    /// `https://api.github.com/applications/{client_id}/token`.
    public static func revocationURL(clientID: String) -> URL {
        let encoded = clientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clientID
        return apiBaseURL.appendingPathComponent("applications/\(encoded)/token")
    }

    // MARK: - Injected dependencies

    /// A single HTTP round-trip. Injected so the request this type builds is
    /// asserted without real network; production wires this to `URLSession`.
    public typealias Transport = @Sendable (Request) async throws -> Response

    /// The GitHub OAuth client id whose token is being revoked. Defaults to
    /// ``GitHubDeviceFlow/defaultClientID`` (Burnbar's registered GitHub App).
    public let clientID: String

    private let transport: Transport

    /// - Parameters:
    ///   - clientID: GitHub OAuth client id. Defaults to
    ///     ``GitHubDeviceFlow/defaultClientID`` (Burnbar's registered GitHub App).
    ///   - transport: HTTP round-trip. Defaults to a `URLSession`-backed
    ///     implementation (``urlSessionTransport``).
    public init(
        clientID: String = GitHubDeviceFlow.defaultClientID,
        transport: @escaping Transport = GitHubTokenRevoker.urlSessionTransport
    ) {
        self.clientID = clientID
        self.transport = transport
    }

    // MARK: - Revoke

    /// Ask GitHub to invalidate `token` for this app.
    ///
    /// Sends `DELETE /applications/{client_id}/token` with body
    /// `{"access_token": token}`. GitHub returns **204 No Content** on success and
    /// **404** when the token is already unknown/revoked — both are treated as
    /// "the token is no longer valid", so the caller can safely clear the local
    /// Keychain next. Any other non-2xx status throws ``RevokeError/httpStatus(_:)``
    /// so a genuine failure (e.g. auth/host error) is surfaced rather than masking
    /// a still-live token.
    ///
    /// - Parameter token: The access token to revoke. Never logged or persisted.
    /// - Throws: ``RevokeError/httpStatus(_:)`` on an unexpected status, or any
    ///   error the injected transport throws (e.g. a network failure).
    public func revoke(token: String) async throws {
        let request = Request(
            url: Self.revocationURL(clientID: clientID),
            accessToken: token
        )
        let response = try await transport(request)

        // 204 = revoked; 404 = already unknown/revoked. Either way the token is
        // dead, so clearing locally is correct. 2xx generally is accepted to be
        // forgiving of GitHub returning 200 with a body.
        if response.status == 404 || (200 ..< 300).contains(response.status) {
            return
        }
        throw RevokeError.httpStatus(response.status)
    }

    // MARK: - Default transport

    /// `URLSession`-backed transport used in production. Tests inject their own.
    ///
    /// Issues an authenticated `DELETE` with the JSON `{"access_token": …}` body
    /// GitHub's revocation endpoint expects. The `Authorization` header carries the
    /// same token (GitHub authenticates the revocation with the token itself, so
    /// the `client_secret` never has to leave the server — preserving the privacy
    /// posture from 3.2.1).
    public static let urlSessionTransport: Transport = { request in
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(request.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = request.jsonBody

        let (_, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        return Response(status: status)
    }
}

// MARK: - Public value types

public extension GitHubTokenRevoker {
    /// An outbound revocation request for the injected ``Transport``. Carries the
    /// endpoint plus the token to revoke, and renders the JSON body GitHub
    /// expects — trivially constructible and assertable in tests.
    struct Request: Sendable, Equatable {
        /// `DELETE` target (`/applications/{client_id}/token`).
        public let url: URL
        /// The access token to revoke, placed in the JSON body and the auth header.
        public let accessToken: String

        public init(url: URL, accessToken: String) {
            self.url = url
            self.accessToken = accessToken
        }

        /// The request body GitHub's revocation endpoint requires:
        /// `{"access_token":"…"}`. Encoded deterministically so tests can assert it.
        public var jsonBody: Data {
            // A single, known key — encode by hand so the output is stable and the
            // token is JSON-escaped without pulling in a Codable wrapper.
            let escaped = Self.jsonEscaped(accessToken)
            return Data("{\"access_token\":\"\(escaped)\"}".utf8)
        }

        /// Minimal JSON string escaping for the token value (quotes/backslashes/
        /// control chars). GitHub tokens are ASCII, but escape defensively.
        private static func jsonEscaped(_ value: String) -> String {
            var out = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out
        }
    }

    /// The injected ``Transport``'s reply: just the HTTP status code (the
    /// revocation endpoint's success is 204 with no body).
    struct Response: Sendable, Equatable {
        /// HTTP status code (e.g. 204, 404, 401).
        public let status: Int

        public init(status: Int) {
            self.status = status
        }
    }

    /// Failures surfaced by ``revoke(token:)``.
    enum RevokeError: Error, Equatable, Sendable {
        /// GitHub returned an unexpected (non-2xx, non-404) status. The associated
        /// value is the raw HTTP status code.
        case httpStatus(Int)
    }
}
