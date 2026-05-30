import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises the pre-upload privacy gate (``UploadPayloadValidator``): the
/// allowlist accepts a well-formed `{date, provider, tokens, cost_usd}` row and
/// rejects every other shape — extra keys (`model`, `machine_id`, `cwd`,
/// `project`, …), missing keys, unknown providers (two-provider cap), wrong
/// value types, and negative numbers. Both entry points (dictionary and raw JSON
/// `Data`) are covered.
final class UploadPayloadValidatorTests: XCTestCase {

    // MARK: - Builders

    /// A canonical, valid row. Tests mutate a copy to construct each bad case.
    private func validPayload() -> [String: Any] {
        [
            "date": "2026-05-30",
            "provider": "claude",
            "tokens": 12_345,
            "cost_usd": 1.23,
        ]
    }

    /// Assert that validating `payload` throws the expected error.
    private func expect(
        _ payload: [String: Any],
        toThrow expected: UploadPayloadValidator.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try UploadPayloadValidator.validate(payload), file: file, line: line) { error in
            XCTAssertEqual(
                error as? UploadPayloadValidator.ValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Valid case

    func testValidPayloadIsAccepted() throws {
        XCTAssertNoThrow(try UploadPayloadValidator.validate(validPayload()))
    }

    func testIntegerCostIsAccepted() throws {
        var payload = validPayload()
        payload["cost_usd"] = 0 // integer 0 is a valid non-negative cost
        XCTAssertNoThrow(try UploadPayloadValidator.validate(payload))
    }

    func testZeroTokensIsAccepted() throws {
        var payload = validPayload()
        payload["tokens"] = 0
        XCTAssertNoThrow(try UploadPayloadValidator.validate(payload))
    }

    func testBothProvidersAreAccepted() throws {
        for provider in ["claude", "codex"] {
            var payload = validPayload()
            payload["provider"] = provider
            XCTAssertNoThrow(
                try UploadPayloadValidator.validate(payload),
                "provider \(provider) should be allowed"
            )
        }
    }

    // MARK: - Extra / unknown keys (the privacy gate)

    func testExtraModelKeyIsRejected() {
        var payload = validPayload()
        payload["model"] = "claude-opus-4-7"
        expect(payload, toThrow: .unexpectedKeys(["model"]))
    }

    func testExtraMachineIDKeyIsRejected() {
        var payload = validPayload()
        payload["machine_id"] = "ABCDEF0123456789"
        expect(payload, toThrow: .unexpectedKeys(["machine_id"]))
    }

    func testExtraCwdKeyIsRejected() {
        var payload = validPayload()
        payload["cwd"] = "/Users/andy/secret-project"
        expect(payload, toThrow: .unexpectedKeys(["cwd"]))
    }

    func testExtraProjectKeyIsRejected() {
        var payload = validPayload()
        payload["project"] = "Burnbar"
        expect(payload, toThrow: .unexpectedKeys(["project"]))
    }

    func testMultipleExtraIdentifyingKeysAreAllReported() {
        var payload = validPayload()
        payload["machine_id"] = "ABCDEF0123456789"
        payload["git_branch"] = "main"
        payload["first_user_message"] = "leak"
        // Keys are reported sorted for determinism.
        expect(payload, toThrow: .unexpectedKeys(["first_user_message", "git_branch", "machine_id"]))
    }

    // MARK: - Missing keys

    func testMissingDateIsRejected() {
        var payload = validPayload()
        payload["date"] = nil
        expect(payload, toThrow: .missingKeys(["date"]))
    }

    func testMissingCostIsRejected() {
        var payload = validPayload()
        payload["cost_usd"] = nil
        expect(payload, toThrow: .missingKeys(["cost_usd"]))
    }

    func testEmptyPayloadReportsAllMissingKeys() {
        expect([:], toThrow: .missingKeys(["cost_usd", "date", "provider", "tokens"]))
    }

    // MARK: - Two-provider cap

    func testUnknownProviderGeminiIsRejected() {
        var payload = validPayload()
        payload["provider"] = "gemini"
        expect(
            payload,
            toThrow: .invalidValue(key: "provider", reason: "\"gemini\" is not one of claude, codex")
        )
    }

    func testProviderWithWrongTypeIsRejected() {
        var payload = validPayload()
        payload["provider"] = 42
        expect(payload, toThrow: .invalidValue(key: "provider", reason: "expected a string"))
    }

    // MARK: - Wrong-typed / out-of-range values

    func testNegativeTokensIsRejected() {
        var payload = validPayload()
        payload["tokens"] = -1
        expect(payload, toThrow: .invalidValue(key: "tokens", reason: "must be >= 0, got -1"))
    }

    func testTokensAsStringIsRejected() {
        var payload = validPayload()
        payload["tokens"] = "12345"
        expect(payload, toThrow: .invalidValue(key: "tokens", reason: "expected a non-negative integer"))
    }

    func testFractionalTokensIsRejected() {
        var payload = validPayload()
        payload["tokens"] = 1.5
        expect(payload, toThrow: .invalidValue(key: "tokens", reason: "expected a non-negative integer"))
    }

    func testBooleanTokensIsRejected() {
        var payload = validPayload()
        payload["tokens"] = true
        expect(payload, toThrow: .invalidValue(key: "tokens", reason: "expected a non-negative integer"))
    }

    func testNegativeCostIsRejected() {
        var payload = validPayload()
        payload["cost_usd"] = -0.01
        expect(payload, toThrow: .invalidValue(key: "cost_usd", reason: "must be >= 0, got -0.01"))
    }

    func testCostAsStringIsRejected() {
        var payload = validPayload()
        payload["cost_usd"] = "1.23"
        expect(payload, toThrow: .invalidValue(key: "cost_usd", reason: "expected a non-negative number"))
    }

    func testMalformedDateIsRejected() {
        var payload = validPayload()
        payload["date"] = "2026/05/30"
        expect(payload, toThrow: .invalidValue(key: "date", reason: "\"2026/05/30\" is not a YYYY-MM-DD date"))
    }

    func testDateWithWrongTypeIsRejected() {
        var payload = validPayload()
        payload["date"] = 20_260_530
        expect(payload, toThrow: .invalidValue(key: "date", reason: "expected a YYYY-MM-DD string"))
    }

    // MARK: - Precedence

    func testUnexpectedKeyTakesPrecedenceOverMissingKey() {
        // Drop a required key AND add an unknown one: the privacy-critical
        // unexpected-key check must fire first.
        var payload = validPayload()
        payload["cost_usd"] = nil
        payload["machine_id"] = "ABCDEF0123456789"
        expect(payload, toThrow: .unexpectedKeys(["machine_id"]))
    }

    // MARK: - JSON Data entry point

    func testValidJSONDataIsAccepted() throws {
        let json = try JSONSerialization.data(withJSONObject: validPayload())
        XCTAssertNoThrow(try UploadPayloadValidator.validate(json: json))
    }

    func testJSONDataWithExtraKeyIsRejected() throws {
        var payload = validPayload()
        payload["rollout_path"] = "/Users/andy/.codex/sessions/abc"
        let json = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try UploadPayloadValidator.validate(json: json)) { error in
            XCTAssertEqual(
                error as? UploadPayloadValidator.ValidationError,
                .unexpectedKeys(["rollout_path"])
            )
        }
    }

    func testJSONDataThatIsAnArrayIsRejected() throws {
        let json = try JSONSerialization.data(withJSONObject: [validPayload()])
        XCTAssertThrowsError(try UploadPayloadValidator.validate(json: json)) { error in
            XCTAssertEqual(error as? UploadPayloadValidator.ValidationError, .notAnObject)
        }
    }

    func testMalformedJSONDataIsRejected() {
        let bytes = Data("{ not json".utf8)
        XCTAssertThrowsError(try UploadPayloadValidator.validate(json: bytes)) { error in
            XCTAssertEqual(error as? UploadPayloadValidator.ValidationError, .notAnObject)
        }
    }

    // MARK: - Allowlist shape

    func testAllowedKeysAreExactlyTheFourSafeKeys() {
        XCTAssertEqual(
            UploadPayloadValidator.allowedKeys,
            ["date", "provider", "tokens", "cost_usd"]
        )
    }

    func testAllowedProvidersMatchTheProviderEnum() {
        XCTAssertEqual(UploadPayloadValidator.allowedProviders, ["claude", "codex"])
    }
}
