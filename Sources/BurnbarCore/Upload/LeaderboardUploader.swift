import Foundation

/// Posts leaderboard-safe daily rollups to the Burnbar API's `POST /api/v1/usage`
/// endpoint (M3, sub-ticket 3.3.4 — the upload client behind the Settings
/// "Upload now" button and the daily scheduler).
///
/// Each row is the four-field, non-identifying ``LeaderboardRecord`` produced by
/// ``LeaderboardAggregator`` (#57). Before *any* byte leaves the machine the
/// uploader re-runs it through the ``UploadPayloadValidator`` privacy gate (#56):
/// the serialized body is decoded and checked against the hard allowlist
/// `{date, provider, tokens, cost_usd}`, so even a regressed upstream aggregator
/// that smuggled in a `machine_id` / `model` / `cwd` would be rejected here rather
/// than uploaded. The request carries the GitHub bearer token from
/// ``KeychainTokenStore`` (#55) as `Authorization: Bearer <token>`.
///
/// ## Testability
/// The HTTP transport is injected as a closure `(URLRequest) async throws ->
/// (Data, Int)` (body + status code), so the whole "validate → build request →
/// POST" path is unit-tested with **no network**: a stub transport captures the
/// `URLRequest` and asserts the body's keys and the `Authorization` header. The
/// type holds only immutable `@Sendable` config, so it is `Sendable` and safe to
/// drive from the scheduler's background task or the Settings main-actor button.
///
/// ## What it does *not* do
/// It performs no aggregation (the caller passes already-aggregated rows), no
/// scheduling (``UploadScheduler`` owns the daily timing), and no queueing on
/// failure (``OfflineUploadQueue`` owns durability). It is the single, focused
/// "send these validated rows now" step.
public struct LeaderboardUploader: Sendable {
    /// A single HTTP round-trip: send the `URLRequest`, get back the response body
    /// and its HTTP status code. Injected so the uploader is exercised with no
    /// real network; production wires ``urlSessionTransport``.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Reads the GitHub bearer token to authorize the upload. Injected (rather than
    /// taking a raw string) so the live wiring reads the Keychain lazily at send
    /// time — a token that changed since construction is still honoured, and a
    /// signed-out state (`nil`) fails fast as ``UploadError/notAuthenticated``
    /// before any row is built.
    public typealias TokenProvider = @Sendable () -> String?

    /// Base URL of the Burnbar API (e.g. `https://api.burnbar.andybowu.xyz`). The
    /// usage endpoint is `apiBase` + ``usagePath``. Injected so tests point it at a
    /// dummy host and the production base lives in one place.
    public let apiBase: URL

    private let token: TokenProvider
    private let transport: Transport

    /// Path of the usage upload endpoint, appended to ``apiBase``. Matches the
    /// Worker route `app.post('/api/v1/usage', …)`.
    public static let usagePath = "/api/v1/usage"

    /// - Parameters:
    ///   - apiBase: Base URL of the Burnbar API. The POST target is this plus
    ///     ``usagePath``.
    ///   - token: Supplies the GitHub bearer token (production: a
    ///     `KeychainTokenStore` read). Returning `nil` means "signed out".
    ///   - transport: HTTP round-trip. Defaults to a `URLSession`-backed
    ///     implementation (``urlSessionTransport``).
    public init(
        apiBase: URL,
        token: @escaping TokenProvider,
        transport: @escaping Transport = LeaderboardUploader.urlSessionTransport
    ) {
        self.apiBase = apiBase
        self.token = token
        self.transport = transport
    }

    /// Why an upload could not complete.
    public enum UploadError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No bearer token was available (the user is signed out). No request is
        /// made.
        case notAuthenticated
        /// A row failed the ``UploadPayloadValidator`` privacy gate before upload.
        /// Carries the underlying validation failure. The whole upload aborts —
        /// nothing is sent — so a bad row never leaks even partially.
        case validationFailed(UploadPayloadValidator.ValidationError)
        /// The server rejected a row with a non-2xx status. Carries the offending
        /// row's `(date, provider)` id and the HTTP status code.
        case server(rowID: String, status: Int)

        public var description: String {
            switch self {
            case .notAuthenticated:
                return "Upload skipped: not signed in to GitHub."
            case let .validationFailed(error):
                return "Upload aborted: \(error)"
            case let .server(rowID, status):
                return "Upload failed for row \(rowID): server returned HTTP \(status)."
            }
        }

        public static func == (lhs: UploadError, rhs: UploadError) -> Bool {
            switch (lhs, rhs) {
            case (.notAuthenticated, .notAuthenticated):
                return true
            case let (.validationFailed(lhsError), .validationFailed(rhsError)):
                return lhsError == rhsError
            case let (.server(lhsID, lhsStatus), .server(rhsID, rhsStatus)):
                return lhsID == rhsID && lhsStatus == rhsStatus
            default:
                return false
            }
        }
    }

    /// Validate and POST every row in `records`, oldest order as given.
    ///
    /// The full pass is **fail-closed**: every row is validated through
    /// ``UploadPayloadValidator`` *before* the first one is sent, so a single
    /// invalid row (or a missing token) aborts the entire upload with nothing on
    /// the wire. Surviving rows are then POSTed one at a time; a non-2xx response
    /// throws ``UploadError/server(rowID:status:)`` and stops the pass (the
    /// scheduler / offline queue owns retry).
    ///
    /// - Parameter records: Leaderboard-safe rows to upload. An empty array is a
    ///   no-op success.
    /// - Returns: The number of rows successfully accepted by the server.
    /// - Throws: ``UploadError`` on missing token, validation failure, or a server
    ///   rejection; or any error the injected transport throws (e.g. offline).
    @discardableResult
    public func upload(_ records: [LeaderboardRecord]) async throws -> Int {
        guard !records.isEmpty else { return 0 }

        guard let bearer = token() else {
            throw UploadError.notAuthenticated
        }

        // Validate the *entire* batch first (fail-closed): build each row's
        // serialized body and run it through the privacy gate. Only if all rows
        // pass do we send anything, so a bad row never leaks even partially.
        let encoder = Self.encoder
        var prepared: [(record: LeaderboardRecord, body: Data)] = []
        prepared.reserveCapacity(records.count)
        for record in records {
            let body = try encoder.encode(record)
            do {
                try UploadPayloadValidator.validate(json: body)
            } catch let error as UploadPayloadValidator.ValidationError {
                throw UploadError.validationFailed(error)
            }
            prepared.append((record, body))
        }

        var accepted = 0
        for item in prepared {
            let request = buildRequest(body: item.body, bearer: bearer)
            let (_, status) = try await transport(request)
            guard (200 ..< 300).contains(status) else {
                throw UploadError.server(rowID: item.record.id, status: status)
            }
            accepted += 1
        }
        return accepted
    }

    /// The fully resolved POST target: ``apiBase`` + ``usagePath``.
    public var usageURL: URL {
        apiBase.appendingPathComponent(Self.usagePath)
    }

    /// Build the `URLRequest` for one already-validated, already-encoded row.
    private func buildRequest(body: Data, bearer: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    /// JSON encoder for the row body. Sorted keys keep the wire payload
    /// deterministic and easy to assert in tests; the ``LeaderboardRecord``
    /// `CodingKeys` already pin the four wire field names.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// `URLSession`-backed transport used in production. Tests inject their own.
    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
