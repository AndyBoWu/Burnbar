import Foundation

/// Drives GitHub's **OAuth Device Flow** (RFC 8628) for Burnbar's M3 leaderboard
/// sign-in (sub-tickets 3.2.2 + 3.2.3).
///
/// The flow is two phases:
/// 1. ``requestDeviceCode()`` — `POST https://github.com/login/device/code` with
///    our `client_id` + `scope`, returning a short `user_code` for the user to
///    type in their browser, a `verification_uri`, a `device_code` to poll with,
///    a poll `interval`, and an `expires_in`.
/// 2. ``pollForToken(deviceCode:interval:)`` — polls
///    `POST https://github.com/login/oauth/access_token` at the GitHub-specified
///    interval until the user authorizes (success → `access_token`), honouring
///    `authorization_pending` (keep polling), `slow_down` (back off), and the
///    terminal `expired_token` / `access_denied` errors, with a hard 15-minute
///    overall timeout.
///
/// ## Privacy (CLAUDE.md, M3)
/// The returned ``Token/accessToken`` is handed straight to
/// ``KeychainTokenStore`` (3.2.4) by the caller — this type never logs, persists,
/// or transmits it anywhere. No browser cookies, no third-party Keychain items.
///
/// ## Testability
/// All non-determinism is injected, so the polling state machine is fully
/// unit-testable with **no real network and no real waiting**:
/// - `transport` — the HTTP round-trip `(Request) async throws -> Response`.
/// - `sleep` — replaces `Task.sleep`; tests pass a no-op to fast-forward.
/// - `now` — the clock used for the timeout; tests advance it synthetically.
///
/// Holds only immutable `@Sendable` closures and value config, so it is
/// `Sendable` and safe to share across concurrency domains.
public struct GitHubDeviceFlow: Sendable {

    // MARK: - Endpoints

    /// `POST` target for phase 1 (request a device + user code).
    public static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!

    /// `POST` target for phase 2 (exchange the device code for an access token).
    public static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    /// The `grant_type` GitHub requires when polling the token endpoint.
    public static let grantType = "urn:ietf:params:oauth:grant-type:device-code"

    /// Placeholder `client_id` shipped until **3.2.1 / #52** registers the real
    /// GitHub App and substitutes the production identifier. Kept obvious so a
    /// build that forgot to wire the real value fails loudly against GitHub rather
    /// than silently half-working.
    public static let placeholderClientID = "REPLACE_AFTER_GITHUB_APP_REGISTRATION"

    /// Hard ceiling on the whole poll loop: 15 minutes. GitHub's `device_code`
    /// itself typically expires around this mark; we enforce our own bound so the
    /// loop always terminates with a clear ``DeviceFlowError/timedOut`` even if the
    /// server never reports `expired_token`.
    public static let pollTimeout: TimeInterval = 15 * 60

    /// Floor applied to any poll interval. GitHub asks clients not to poll faster
    /// than every 5 s; we never go below this even if a response omits `interval`.
    public static let minimumIntervalSeconds = 5

    // MARK: - Injected dependencies

    /// A single HTTP round-trip. Injected so the state machine is exercised
    /// without real network: production wires this to `URLSession`.
    public typealias Transport = @Sendable (Request) async throws -> Response

    /// A cancellable wait of `seconds`. Injected so tests fast-forward instantly;
    /// production wires this to `Task.sleep`.
    public typealias Sleep = @Sendable (_ seconds: Double) async throws -> Void

    /// The GitHub OAuth client id. Defaults to ``placeholderClientID``.
    public let clientID: String

    /// OAuth scopes requested in phase 1 (space-delimited per the spec).
    public let scope: String

    private let transport: Transport
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - clientID: GitHub OAuth client id. Defaults to ``placeholderClientID``
    ///     until #52 registers the real GitHub App.
    ///   - scope: Space-delimited OAuth scopes. Defaults to empty (no extra
    ///     scope — Burnbar only needs to identify the user for the leaderboard).
    ///   - transport: HTTP round-trip. Defaults to a `URLSession`-backed
    ///     implementation (``urlSessionTransport``).
    ///   - sleep: Cancellable wait. Defaults to `Task.sleep`.
    ///   - now: Clock for the timeout. Defaults to `Date.init`.
    public init(
        clientID: String = GitHubDeviceFlow.placeholderClientID,
        scope: String = "",
        transport: @escaping Transport = GitHubDeviceFlow.urlSessionTransport,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientID = clientID
        self.scope = scope
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Phase 1: request a device code

    /// Request a fresh device + user code from GitHub.
    ///
    /// - Returns: The decoded ``DeviceCode`` to show the user and to poll with.
    /// - Throws: ``DeviceFlowError/server(error:description:)`` if GitHub returns
    ///   an error body, ``DeviceFlowError/httpStatus(_:)`` on a non-2xx response,
    ///   or ``DeviceFlowError/decoding`` if the JSON cannot be parsed.
    public func requestDeviceCode() async throws -> DeviceCode {
        var fields = ["client_id": clientID]
        if !scope.isEmpty {
            fields["scope"] = scope
        }
        let request = Request(url: Self.deviceCodeURL, formFields: fields)
        let response = try await transport(request)

        if let payload = try? Self.decoder.decode(ErrorPayload.self, from: response.data),
           let code = payload.error {
            throw DeviceFlowError.server(error: code, description: payload.errorDescription)
        }
        guard (200 ..< 300).contains(response.status) else {
            throw DeviceFlowError.httpStatus(response.status)
        }
        guard let decoded = try? Self.decoder.decode(DeviceCodeResponse.self, from: response.data) else {
            throw DeviceFlowError.decoding
        }
        return DeviceCode(
            deviceCode: decoded.deviceCode,
            userCode: decoded.userCode,
            verificationURI: decoded.verificationURI,
            interval: max(decoded.interval ?? Self.minimumIntervalSeconds, Self.minimumIntervalSeconds),
            expiresIn: decoded.expiresIn ?? Int(Self.pollTimeout)
        )
    }

    // MARK: - Phase 2: poll for the access token

    /// Poll the token endpoint until the user authorizes, the request is denied,
    /// the device code expires, or the 15-minute timeout elapses.
    ///
    /// The interval starts at `interval` (clamped to ``minimumIntervalSeconds``)
    /// and grows whenever GitHub returns `slow_down`: GitHub may include a fresh
    /// `interval`, otherwise we add a 5 s penalty as the spec recommends.
    ///
    /// - Parameters:
    ///   - deviceCode: The `device_code` from ``requestDeviceCode()``.
    ///   - interval: Initial seconds between polls (GitHub's suggested `interval`).
    /// - Returns: The decoded ``Token`` on success. The caller hands its
    ///   ``Token/accessToken`` to the Keychain (3.2.4); this type never stores it.
    /// - Throws: ``DeviceFlowError/timedOut`` after 15 minutes (retry by calling
    ///   ``requestDeviceCode()`` again), ``DeviceFlowError/accessDenied`` if the
    ///   user rejects, ``DeviceFlowError/expiredToken`` if the device code
    ///   expires, or ``DeviceFlowError/server(error:description:)`` for any other
    ///   GitHub error.
    public func pollForToken(deviceCode: String, interval: Int) async throws -> Token {
        let deadline = now().addingTimeInterval(Self.pollTimeout)
        var currentInterval = max(interval, Self.minimumIntervalSeconds)

        while true {
            // Enforce the hard overall timeout *before* sleeping/polling so we
            // never wait past the 15-minute bound.
            guard now() < deadline else {
                throw DeviceFlowError.timedOut
            }

            try await sleep(Double(currentInterval))

            // Re-check after waking: a slow poll near the boundary must not slip
            // through and issue a request past the deadline.
            guard now() < deadline else {
                throw DeviceFlowError.timedOut
            }

            let request = Request(
                url: Self.accessTokenURL,
                formFields: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": Self.grantType
                ]
            )
            let response = try await transport(request)

            switch try Self.classify(response) {
            case let .success(token):
                return token
            case .keepPolling:
                continue
            case let .slowDown(newInterval):
                // Honour GitHub's new interval if present, else add the 5 s
                // penalty the spec recommends.
                currentInterval = max(newInterval ?? currentInterval + 5, currentInterval + 5)
            case let .fail(error):
                throw error
            }
        }
    }

    // MARK: - Response classification

    /// One iteration's verdict for the poll loop.
    private enum PollOutcome {
        case success(Token)
        case keepPolling
        case slowDown(newInterval: Int?)
        case fail(DeviceFlowError)
    }

    /// Map a raw token-endpoint response to a ``PollOutcome``.
    ///
    /// GitHub returns HTTP 200 for *both* success and the in-flight error codes
    /// (`authorization_pending`, `slow_down`), distinguishing them only in the
    /// JSON body, so the body is inspected before the status.
    private static func classify(_ response: Response) throws -> PollOutcome {
        if let token = try? decoder.decode(TokenResponse.self, from: response.data),
           let accessToken = token.accessToken, !accessToken.isEmpty {
            return .success(
                Token(
                    accessToken: accessToken,
                    tokenType: token.tokenType ?? "bearer",
                    scope: token.scope ?? ""
                )
            )
        }

        guard let payload = try? decoder.decode(ErrorPayload.self, from: response.data),
              let code = payload.error else {
            // No token and no recognisable error body: treat a non-2xx as an HTTP
            // failure, otherwise a decoding failure.
            if !(200 ..< 300).contains(response.status) {
                return .fail(.httpStatus(response.status))
            }
            return .fail(.decoding)
        }

        switch code {
        case "authorization_pending":
            return .keepPolling
        case "slow_down":
            return .slowDown(newInterval: payload.interval)
        case "expired_token":
            return .fail(.expiredToken)
        case "access_denied":
            return .fail(.accessDenied)
        default:
            return .fail(.server(error: code, description: payload.errorDescription))
        }
    }

    // MARK: - Default transport

    /// `URLSession`-backed transport used in production. Tests inject their own.
    public static let urlSessionTransport: Transport = { request in
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // GitHub returns form-encoded by default; ask for JSON so both phases
        // decode uniformly.
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = Data(request.formBody.utf8)

        let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        return Response(data: data, status: status)
    }

    /// JSON decoder shared by both phases. GitHub uses snake_case keys; explicit
    /// `CodingKeys` on each wire type map them, so no key-decoding strategy is set.
    private static let decoder = JSONDecoder()
}

// MARK: - Public value types

public extension GitHubDeviceFlow {
    /// An outbound HTTP request for the injected ``Transport``. Carries enough to
    /// build a real `URLRequest` while staying trivially constructible in tests.
    struct Request: Sendable, Equatable {
        /// Endpoint to POST to.
        public let url: URL
        /// Form fields, serialised into an `application/x-www-form-urlencoded` body.
        public let formFields: [String: String]

        public init(url: URL, formFields: [String: String]) {
            self.url = url
            self.formFields = formFields
        }

        /// The fields rendered as a percent-encoded `a=b&c=d` body, with keys
        /// sorted so the output is deterministic (stable across runs and easy to
        /// assert in tests).
        public var formBody: String {
            formFields
                .sorted { $0.key < $1.key }
                .map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }
                .joined(separator: "&")
        }

        private static func encode(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
    }

    /// The injected ``Transport``'s reply: the raw body plus the HTTP status code.
    struct Response: Sendable, Equatable {
        /// Raw response body to decode.
        public let data: Data
        /// HTTP status code (e.g. 200, 400).
        public let status: Int

        public init(data: Data, status: Int) {
            self.data = data
            self.status = status
        }
    }

    /// Phase-1 result: what to show the user and what to poll with.
    struct DeviceCode: Sendable, Equatable {
        /// Opaque code passed to ``pollForToken(deviceCode:interval:)``.
        public let deviceCode: String
        /// Short human code the user types at ``verificationURI``.
        public let userCode: String
        /// Browser URL where the user enters ``userCode``.
        public let verificationURI: String
        /// Suggested seconds between polls (clamped to ≥ ``minimumIntervalSeconds``).
        public let interval: Int
        /// Seconds until ``deviceCode`` expires.
        public let expiresIn: Int

        public init(
            deviceCode: String,
            userCode: String,
            verificationURI: String,
            interval: Int,
            expiresIn: Int
        ) {
            self.deviceCode = deviceCode
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.interval = interval
            self.expiresIn = expiresIn
        }
    }

    /// Phase-2 success: the access token to hand to the Keychain (3.2.4).
    struct Token: Sendable, Equatable {
        /// The bearer token. Privacy-sensitive — never log or persist outside the
        /// Keychain.
        public let accessToken: String
        /// Token type GitHub reports (typically `bearer`).
        public let tokenType: String
        /// Granted scopes (space-delimited); empty when none requested.
        public let scope: String

        public init(accessToken: String, tokenType: String, scope: String) {
            self.accessToken = accessToken
            self.tokenType = tokenType
            self.scope = scope
        }
    }

    /// Failures surfaced by either phase.
    enum DeviceFlowError: Error, Equatable, Sendable {
        /// The 15-minute poll budget elapsed. Recoverable: request a new device
        /// code and poll again.
        case timedOut
        /// The user explicitly rejected the authorization (`access_denied`).
        case accessDenied
        /// The device code expired before the user authorized (`expired_token`).
        case expiredToken
        /// A non-2xx HTTP status with no recognisable error body.
        case httpStatus(Int)
        /// The response body could not be decoded as either a token or an error.
        case decoding
        /// Any other GitHub-reported error, with its raw `error` code and optional
        /// `error_description`.
        case server(error: String, description: String?)
    }
}

// MARK: - Wire types (file-private Decodable mirrors of GitHub's JSON)

//
// Kept at file scope rather than nested inside `GitHubDeviceFlow` so the
// `CodingKeys` enums don't exceed SwiftLint's nesting depth. `private` here means
// file-private, so they stay invisible outside this file.

/// Decodes the phase-1 device-code response.
private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let interval: Int?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case interval
        case expiresIn = "expires_in"
    }
}

/// Decodes the phase-2 success body.
private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}

/// Decodes GitHub's error body (used by both phases). `interval` rides along
/// because the `slow_down` error carries a fresh poll interval.
private struct ErrorPayload: Decodable {
    let error: String?
    let errorDescription: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case interval
    }
}
