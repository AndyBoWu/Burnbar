import Foundation

/// Issues the "delete all my data" request against the Burnbar API's
/// `DELETE /api/v1/me` endpoint (M3, sub-ticket 3.5.2 — the destructive control
/// behind the Settings "Delete all my data" button).
///
/// The endpoint removes every server-side row for the authenticated user — the
/// `users` record and all `daily_usage` rows — keyed off the `github_id` the
/// server derives from the bearer token. The request therefore carries **only**
/// the GitHub bearer token from ``KeychainTokenStore`` (#55) as
/// `Authorization: Bearer <token>` and sends **no body**: the identity comes from
/// the token server-side, so the client never transmits a `github_id`, login, or
/// any other field. This keeps the payload aligned with the privacy thesis
/// (CLAUDE.md M3 — never upload identifying data).
///
/// ## Testability
/// The HTTP transport is injected as a closure `(URLRequest) async throws ->
/// (Data, Int)` (body + status code), mirroring ``LeaderboardUploader`` and
/// ``GitHubTokenRevoker``, so the whole "read token → build request → DELETE"
/// path is unit-tested with **no network**: a stub transport captures the
/// `URLRequest` and asserts the method, URL, `Authorization` header, and the
/// absence of a body. The type holds only immutable `@Sendable` config, so it is
/// `Sendable` and safe to drive from the Settings main-actor button.
///
/// ## What it does *not* do
/// It performs **no local teardown**. Clearing the Keychain token and resetting
/// the opt-in flag is the caller's job, run only *after* this returns
/// successfully — so a failed server delete never strands the user with no local
/// credentials and orphaned server rows (mirrors the revoke-then-clear ordering
/// in ``AuthController``).
public struct AccountDeleter: Sendable {
    /// A single HTTP round-trip: send the `URLRequest`, get back the response body
    /// and its HTTP status code. Injected so the deleter is exercised with no real
    /// network; production wires ``urlSessionTransport``.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Reads the GitHub bearer token to authorize the delete. Injected (rather than
    /// taking a raw string) so the live wiring reads the Keychain lazily at call
    /// time, and a signed-out state (`nil`) fails fast as
    /// ``DeleteError/notAuthenticated`` before any request is built.
    public typealias TokenProvider = @Sendable () -> String?

    /// Base URL of the Burnbar API (e.g. `https://api.burnbar.andybowu.xyz`). The
    /// delete endpoint is `apiBase` + ``mePath``. Injected so tests point it at a
    /// dummy host and the production base lives in one place.
    public let apiBase: URL

    private let token: TokenProvider
    private let transport: Transport

    /// Path of the account-delete endpoint, appended to ``apiBase``. Matches the
    /// Worker route `app.delete('/api/v1/me', …)`.
    public static let mePath = "/api/v1/me"

    /// - Parameters:
    ///   - apiBase: Base URL of the Burnbar API. The DELETE target is this plus
    ///     ``mePath``.
    ///   - token: Supplies the GitHub bearer token (production: a
    ///     `KeychainTokenStore` read). Returning `nil` means "signed out".
    ///   - transport: HTTP round-trip. Defaults to a `URLSession`-backed
    ///     implementation (``urlSessionTransport``).
    public init(
        apiBase: URL,
        token: @escaping TokenProvider,
        transport: @escaping Transport = AccountDeleter.urlSessionTransport
    ) {
        self.apiBase = apiBase
        self.token = token
        self.transport = transport
    }

    /// Why an account delete could not complete.
    public enum DeleteError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No bearer token was available (the user is signed out). No request is
        /// made.
        case notAuthenticated
        /// The bearer token was rejected by the server (HTTP 401). The session is
        /// no longer valid; nothing was deleted under this token.
        case unauthorized
        /// The server returned an unexpected non-2xx, non-401 status. Carries the
        /// raw HTTP status code.
        case server(status: Int)

        public var description: String {
            switch self {
            case .notAuthenticated:
                return "Delete skipped: not signed in to GitHub."
            case .unauthorized:
                return "Your session has expired. Sign in again, then retry."
            case let .server(status):
                return "Couldn't delete your data: the server returned HTTP \(status). Please try again."
            }
        }
    }

    /// Send `DELETE /api/v1/me` to erase all server-side data for the authenticated
    /// user.
    ///
    /// The request carries the bearer token and **no body** — the server resolves
    /// the `github_id` from the token and deletes the matching `users` and
    /// `daily_usage` rows. A 2xx status (the documented success, including 204 No
    /// Content) returns normally so the caller may then tear down local state. A
    /// 401 throws ``DeleteError/unauthorized`` (the token is stale — nothing was
    /// deleted), and any other non-2xx throws ``DeleteError/server(status:)``, so
    /// the caller keeps local state and surfaces a retryable error rather than
    /// clearing credentials against a server that still holds the rows.
    ///
    /// - Throws: ``DeleteError`` on a missing token, a 401, or an unexpected
    ///   status; or any error the injected transport throws (e.g. offline).
    public func deleteAccount() async throws {
        guard let bearer = token() else {
            throw DeleteError.notAuthenticated
        }

        let request = buildRequest(bearer: bearer)
        let (_, status) = try await transport(request)

        if (200 ..< 300).contains(status) {
            return
        }
        if status == 401 {
            throw DeleteError.unauthorized
        }
        throw DeleteError.server(status: status)
    }

    /// The fully resolved DELETE target: ``apiBase`` + ``mePath``.
    public var meURL: URL {
        apiBase.appendingPathComponent(Self.mePath)
    }

    /// Build the bodyless, bearer-authenticated `DELETE` request. No `httpBody` is
    /// set — the server derives the `github_id` from the token, so no identifying
    /// field ever leaves the machine.
    private func buildRequest(bearer: String) -> URLRequest {
        var request = URLRequest(url: meURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// `URLSession`-backed transport used in production. Tests inject their own.
    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
