import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``GitHubDeviceFlow``'s polling state machine with a fully injected
/// HTTP transport, a no-op sleep, and a synthetic clock — so the tests run
/// instantly with **no real network and no real 15-minute wait**.
///
/// Covers the Definition of Done: on success the token is received; on timeout a
/// clear error is thrown and a retry is possible. The required scenarios —
/// pending→success, `slow_down` handling, `expired_token`, `access_denied`, and
/// the timeout — each have a case below.
final class GitHubDeviceFlowTests: XCTestCase {

    // MARK: - Test transport

    /// A scripted transport: returns queued responses in order, recording every
    /// request it received. An `actor` so it is `Sendable` and safe to capture in
    /// the `@Sendable` transport closure.
    private actor ScriptedTransport {
        private var responses: [GitHubDeviceFlow.Response]
        private(set) var requests: [GitHubDeviceFlow.Request] = []
        /// When the script runs dry, this is returned for every further poll —
        /// lets a "pending forever" timeout test poll indefinitely.
        private let fallback: GitHubDeviceFlow.Response

        init(_ responses: [GitHubDeviceFlow.Response], fallback: GitHubDeviceFlow.Response) {
            self.responses = responses
            self.fallback = fallback
        }

        func next(_ request: GitHubDeviceFlow.Request) -> GitHubDeviceFlow.Response {
            requests.append(request)
            guard !responses.isEmpty else { return fallback }
            return responses.removeFirst()
        }

        var requestCount: Int { requests.count }
        var capturedRequests: [GitHubDeviceFlow.Request] { requests }
    }

    /// A monotonic synthetic clock the flow reads via its injected `now`. Each
    /// read advances by `step`, so the 15-minute deadline is reached after a
    /// bounded number of polls without any real time passing.
    private final class FakeClock: @unchecked Sendable {
        private let start: Date
        private let step: TimeInterval
        private let lock = NSLock()
        private var ticks = 0

        init(start: Date = Date(timeIntervalSince1970: 0), step: TimeInterval) {
            self.start = start
            self.step = step
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            let date = start.addingTimeInterval(step * Double(ticks))
            ticks += 1
            return date
        }
    }

    // MARK: - Response builders

    private func response(_ json: String, status: Int = 200) -> GitHubDeviceFlow.Response {
        GitHubDeviceFlow.Response(data: Data(json.utf8), status: status)
    }

    private func pendingResponse() -> GitHubDeviceFlow.Response {
        response(#"{"error":"authorization_pending","error_description":"pending"}"#)
    }

    private func successResponse() -> GitHubDeviceFlow.Response {
        response(#"{"access_token":"gho_TESTTOKEN","token_type":"bearer","scope":""}"#)
    }

    /// Build a flow wired to a scripted transport, a no-op sleep, and a fake clock.
    private func makeFlow(
        responses: [GitHubDeviceFlow.Response],
        fallback: GitHubDeviceFlow.Response,
        clockStep: TimeInterval,
        sleepSpy: (@Sendable (Double) -> Void)? = nil
    ) -> (GitHubDeviceFlow, ScriptedTransport) {
        let transport = ScriptedTransport(responses, fallback: fallback)
        let clock = FakeClock(step: clockStep)
        let flow = GitHubDeviceFlow(
            clientID: "test-client-id",
            transport: { request in await transport.next(request) },
            sleep: { seconds in sleepSpy?(seconds) },
            now: { clock.now() }
        )
        return (flow, transport)
    }

    // MARK: - Phase 1: requestDeviceCode

    func testRequestDeviceCodeDecodesAndPostsClientID() async throws {
        let body = """
        {"device_code":"dc_123","user_code":"WDJB-MJHT",\
        "verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """
        let transport = ScriptedTransport([response(body)], fallback: response(body))
        let flow = GitHubDeviceFlow(
            clientID: "test-client-id",
            scope: "read:user",
            transport: { request in await transport.next(request) },
            sleep: { _ in },
            now: { Date() }
        )

        let code = try await flow.requestDeviceCode()

        XCTAssertEqual(code.deviceCode, "dc_123")
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.verificationURI, "https://github.com/login/device")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.expiresIn, 900)

        // The request POSTed our client_id and scope to the device-code endpoint.
        let requests = await transport.capturedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, GitHubDeviceFlow.deviceCodeURL)
        XCTAssertEqual(requests.first?.formFields["client_id"], "test-client-id")
        XCTAssertEqual(requests.first?.formFields["scope"], "read:user")
    }

    func testRequestDeviceCodeClampsTinyIntervalToMinimum() async throws {
        let body = """
        {"device_code":"dc","user_code":"AAAA-BBBB",\
        "verification_uri":"https://github.com/login/device","interval":1}
        """
        let transport = ScriptedTransport([response(body)], fallback: response(body))
        let flow = GitHubDeviceFlow(
            transport: { request in await transport.next(request) },
            sleep: { _ in },
            now: { Date() }
        )

        let code = try await flow.requestDeviceCode()
        XCTAssertEqual(code.interval, GitHubDeviceFlow.minimumIntervalSeconds)
    }

    // MARK: - Phase 2: pending -> success

    func testPollPendingThenSuccess() async throws {
        // Two pending replies, then the token. Clock barely advances so the
        // 15-minute deadline is never hit.
        let (flow, transport) = makeFlow(
            responses: [pendingResponse(), pendingResponse(), successResponse()],
            fallback: successResponse(),
            clockStep: 1
        )

        let token = try await flow.pollForToken(deviceCode: "dc_123", interval: 5)

        XCTAssertEqual(token.accessToken, "gho_TESTTOKEN")
        XCTAssertEqual(token.tokenType, "bearer")
        // Exactly three polls: pending, pending, success.
        let count = await transport.requestCount
        XCTAssertEqual(count, 3)
        // Every poll carried the device_code + grant_type.
        let requests = await transport.capturedRequests
        XCTAssertEqual(requests.first?.formFields["device_code"], "dc_123")
        XCTAssertEqual(requests.first?.formFields["grant_type"], GitHubDeviceFlow.grantType)
        XCTAssertEqual(requests.first?.url, GitHubDeviceFlow.accessTokenURL)
    }

    // MARK: - slow_down handling

    func testSlowDownIncreasesInterval() async throws {
        // pending(5s) -> slow_down(new interval 10) -> success.
        let slowDown = response(#"{"error":"slow_down","interval":10}"#)
        let recorded = SleepRecorder()
        let (flow, _) = makeFlow(
            responses: [pendingResponse(), slowDown, successResponse()],
            fallback: successResponse(),
            clockStep: 1,
            sleepSpy: { seconds in recorded.record(seconds) }
        )

        let token = try await flow.pollForToken(deviceCode: "dc", interval: 5)
        XCTAssertEqual(token.accessToken, "gho_TESTTOKEN")

        // Sleeps: before poll 1 = 5, before poll 2 = 5 (still 5 until slow_down
        // seen), before poll 3 = 10 (GitHub's new interval honoured).
        let waits = recorded.values
        XCTAssertEqual(waits, [5, 5, 10])
    }

    func testSlowDownWithoutIntervalAddsFiveSecondPenalty() async throws {
        // slow_down with no interval field -> spec says add 5s to the current one.
        let slowDown = response(#"{"error":"slow_down"}"#)
        let recorded = SleepRecorder()
        let (flow, _) = makeFlow(
            responses: [slowDown, successResponse()],
            fallback: successResponse(),
            clockStep: 1,
            sleepSpy: { seconds in recorded.record(seconds) }
        )

        _ = try await flow.pollForToken(deviceCode: "dc", interval: 5)

        // Sleep 1 = 5 (initial), sleep 2 = 10 (5 + 5 penalty).
        XCTAssertEqual(recorded.values, [5, 10])
    }

    // MARK: - expired_token -> error

    func testExpiredTokenThrows() async {
        let expired = response(#"{"error":"expired_token","error_description":"expired"}"#)
        let (flow, _) = makeFlow(
            responses: [pendingResponse(), expired],
            fallback: expired,
            clockStep: 1
        )

        do {
            _ = try await flow.pollForToken(deviceCode: "dc", interval: 5)
            XCTFail("expected expiredToken error")
        } catch {
            XCTAssertEqual(error as? GitHubDeviceFlow.DeviceFlowError, .expiredToken)
        }
    }

    // MARK: - access_denied -> error

    func testAccessDeniedThrows() async {
        let denied = response(#"{"error":"access_denied","error_description":"denied"}"#)
        let (flow, _) = makeFlow(
            responses: [pendingResponse(), denied],
            fallback: denied,
            clockStep: 1
        )

        do {
            _ = try await flow.pollForToken(deviceCode: "dc", interval: 5)
            XCTFail("expected accessDenied error")
        } catch {
            XCTAssertEqual(error as? GitHubDeviceFlow.DeviceFlowError, .accessDenied)
        }
    }

    // MARK: - Timeout

    func testTimeoutThrowsAfterFifteenMinutes() async {
        // Always-pending transport + a clock that jumps 6 minutes per read, so the
        // 15-minute deadline is crossed after a few polls — no real waiting, and
        // the loop is guaranteed to terminate.
        let (flow, transport) = makeFlow(
            responses: [],
            fallback: pendingResponse(),
            clockStep: 6 * 60
        )

        do {
            _ = try await flow.pollForToken(deviceCode: "dc", interval: 5)
            XCTFail("expected timedOut error")
        } catch {
            XCTAssertEqual(error as? GitHubDeviceFlow.DeviceFlowError, .timedOut)
        }

        // A bounded number of polls happened, then the loop gave up — proving the
        // timeout actually fires rather than looping forever.
        let count = await transport.requestCount
        XCTAssertLessThanOrEqual(count, 3)
    }

    func testRetryAfterTimeoutSucceeds() async throws {
        // Definition of Done: after a timeout the caller can retry. A fresh flow
        // (as the Settings VM would build on "Try again") reaches success.
        let timingOut = makeFlow(responses: [], fallback: pendingResponse(), clockStep: 6 * 60).0
        do {
            _ = try await timingOut.pollForToken(deviceCode: "dc", interval: 5)
            XCTFail("expected first attempt to time out")
        } catch {
            XCTAssertEqual(error as? GitHubDeviceFlow.DeviceFlowError, .timedOut)
        }

        let (retry, _) = makeFlow(
            responses: [pendingResponse(), successResponse()],
            fallback: successResponse(),
            clockStep: 1
        )
        let token = try await retry.pollForToken(deviceCode: "dc", interval: 5)
        XCTAssertEqual(token.accessToken, "gho_TESTTOKEN")
    }

    // MARK: - Defaults

    func testDefaultClientIDIsTheRegisteredGitHubApp() {
        let flow = GitHubDeviceFlow()
        XCTAssertEqual(flow.clientID, GitHubDeviceFlow.defaultClientID)
        XCTAssertEqual(GitHubDeviceFlow.defaultClientID, "Iv23liZtq4q4ukHeLwsh")
    }
}

/// Thread-safe recorder for the sequence of sleep durations the flow requested.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ seconds: Double) {
        lock.lock()
        recorded.append(seconds)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
