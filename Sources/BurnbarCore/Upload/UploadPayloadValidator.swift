import Foundation

/// The pre-upload **privacy gate**: the last code that inspects an outbound
/// leaderboard payload before it can leave the machine (M3, sub-ticket 3.3.3).
///
/// Burnbar's whole privacy thesis (CLAUDE.md load-bearing constraint #4) is that
/// the leaderboard upload carries **only** four non-identifying fields —
/// `date`, `provider`, `tokens`, `cost_usd` — and *nothing* else. No
/// `machine_id`, no raw `model` name, no `cwd` / `git_*` / `rollout_path` /
/// project directory name, no `first_user_message` / `preview` / `title` /
/// `message.content`. This validator enforces that as a hard, fail-closed
/// allowlist so that even if some upstream aggregator regresses and stuffs an
/// extra key into a row, the upload is rejected rather than silently leaking it.
///
/// It is a **pure** value type — no I/O, no network, no clock, no global state —
/// so it is trivially `Sendable` and fully unit-testable. The uploader is
/// expected to call ``validate(_:)`` (or ``validate(json:)``) on **every** row
/// and abort the *entire* upload if any row throws (never partially upload).
///
/// ## What "validate" means here
/// The check is performed on the already-**serialized** shape of a row, because
/// that serialized shape is exactly what would hit the wire. Two equivalent
/// entry points are offered:
///
/// - ``validate(_:)`` takes a `[String: Any]` dictionary (e.g. the result of
///   `JSONSerialization.jsonObject`), and
/// - ``validate(json:)`` takes the raw JSON `Data` of an encoded row and decodes
///   it *strictly* into a dictionary first, so any unknown key is detectable
///   (Swift's synthesized `Codable` would silently ignore unknown keys, which is
///   precisely the leak this gate must catch — so we never rely on it).
///
/// Both funnel into the same key-set + value-constraint check.
public enum UploadPayloadValidator: Sendable {
    /// The exact, total set of top-level keys an outbound row may contain. The
    /// payload must match this set exactly — no missing keys, no extra keys.
    ///
    /// Deliberately a hard-coded literal (not derived from a `Codable` type) so
    /// that adding a field to some upstream model can never widen this allowlist
    /// by accident. Widening it is a conscious, reviewed change here, and per
    /// CLAUDE.md only non-identifying fields may ever be added.
    public static let allowedKeys: Set<String> = ["date", "provider", "tokens", "cost_usd"]

    /// The two providers Burnbar supports, as they appear on the wire. Enforces
    /// the two-provider hard cap (CLAUDE.md constraint #2) at the gate: a
    /// `provider` value outside this set is rejected even though `provider` is an
    /// allowed *key*.
    public static let allowedProviders: Set<String> = Set(Provider.allCases.map(\.rawValue))

    /// Matches a `YYYY-MM-DD` calendar day (the canonical `UsageRecord.day`
    /// format). Zero-padded, exactly four/two/two digits, nothing else.
    private static let dateFormat = #"^\d{4}-\d{2}-\d{2}$"#

    /// Why a payload was refused. Every case names the offending key(s)/value so
    /// the failure is actionable in logs and in tests; `CustomStringConvertible`
    /// renders a clear English sentence.
    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        /// The payload carried one or more keys outside ``allowedKeys`` (e.g.
        /// `machine_id`, `model`, `cwd`). Carries the offending keys, sorted.
        case unexpectedKeys([String])
        /// A required key from ``allowedKeys`` was absent. Carries the missing
        /// keys, sorted.
        case missingKeys([String])
        /// A key was present but its value had the wrong type (e.g. `tokens` as a
        /// string) or violated a constraint (e.g. a malformed `date`, an unknown
        /// `provider`, or a negative `tokens` / `cost_usd`). Carries the key and a
        /// short reason.
        case invalidValue(key: String, reason: String)
        /// The supplied JSON `Data` was not a single JSON object (e.g. it was an
        /// array, a bare scalar, or malformed bytes).
        case notAnObject

        public var description: String {
            switch self {
            case let .unexpectedKeys(keys):
                return "Payload rejected: contains key(s) outside the allowlist {date, provider, tokens, cost_usd}: \(keys.joined(separator: ", "))."
            case let .missingKeys(keys):
                return "Payload rejected: missing required key(s): \(keys.joined(separator: ", "))."
            case let .invalidValue(key, reason):
                return "Payload rejected: invalid value for \"\(key)\": \(reason)."
            case .notAnObject:
                return "Payload rejected: expected a single JSON object."
            }
        }
    }

    /// Validate the serialized JSON `Data` of one outbound row.
    ///
    /// Decodes strictly into a `[String: Any]` dictionary via
    /// `JSONSerialization` (which preserves *every* key, so unknown keys remain
    /// detectable — unlike a synthesized `Codable` decode), then applies the same
    /// allowlist + value checks as ``validate(_:)``.
    ///
    /// - Parameter json: The UTF-8 JSON bytes of a single encoded row.
    /// - Throws: ``ValidationError/notAnObject`` if the bytes are not a JSON
    ///   object, or any error ``validate(_:)`` would raise.
    public static func validate(json: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: json)
        } catch {
            throw ValidationError.notAnObject
        }
        guard let dictionary = object as? [String: Any] else {
            throw ValidationError.notAnObject
        }
        try validate(dictionary)
    }

    /// Validate one outbound row already deserialized into a `[String: Any]`.
    ///
    /// Order of checks: key set first (the privacy-critical part — an extra key
    /// is rejected before any value is even inspected), then per-key value
    /// constraints.
    ///
    /// - Parameter payload: The row's top-level key/value pairs as they would be
    ///   serialized for upload.
    /// - Throws: ``ValidationError`` describing the first failure encountered
    ///   (unexpected keys take precedence over missing keys, which take
    ///   precedence over value problems).
    public static func validate(_ payload: [String: Any]) throws {
        let keys = Set(payload.keys)

        // 1. Privacy gate: any key outside the allowlist is an immediate, hard
        //    rejection. This is the check that stops machine_id/model/cwd/etc.
        let unexpected = keys.subtracting(allowedKeys)
        if !unexpected.isEmpty {
            throw ValidationError.unexpectedKeys(unexpected.sorted())
        }

        // 2. Completeness: every allowed key must be present (no partial rows).
        let missing = allowedKeys.subtracting(keys)
        if !missing.isEmpty {
            throw ValidationError.missingKeys(missing.sorted())
        }

        // 3. Value constraints. The key set is now exactly the allowlist, so each
        //    lookup below is guaranteed present.
        try validateDate(payload["date"])
        try validateProvider(payload["provider"])
        try validateNonNegativeInteger(payload["tokens"], key: "tokens")
        try validateNonNegativeNumber(payload["cost_usd"], key: "cost_usd")
    }

    // MARK: - Value checks

    /// `date` must be a `YYYY-MM-DD` string.
    private static func validateDate(_ value: Any?) throws {
        guard let date = value as? String else {
            throw ValidationError.invalidValue(key: "date", reason: "expected a YYYY-MM-DD string")
        }
        guard date.range(of: dateFormat, options: .regularExpression) != nil else {
            throw ValidationError.invalidValue(key: "date", reason: "\"\(date)\" is not a YYYY-MM-DD date")
        }
    }

    /// `provider` must be a string within the two-provider cap.
    private static func validateProvider(_ value: Any?) throws {
        guard let provider = value as? String else {
            throw ValidationError.invalidValue(key: "provider", reason: "expected a string")
        }
        guard allowedProviders.contains(provider) else {
            throw ValidationError.invalidValue(
                key: "provider",
                reason: "\"\(provider)\" is not one of \(allowedProviders.sorted().joined(separator: ", "))"
            )
        }
    }

    /// `tokens` must be a non-negative integer. Rejects booleans (which bridge to
    /// `NSNumber`) and any fractional value.
    private static func validateNonNegativeInteger(_ value: Any?, key: String) throws {
        guard let number = integer(from: value) else {
            throw ValidationError.invalidValue(key: key, reason: "expected a non-negative integer")
        }
        guard number >= 0 else {
            throw ValidationError.invalidValue(key: key, reason: "must be >= 0, got \(number)")
        }
    }

    /// `cost_usd` must be a non-negative number (integer or fractional).
    private static func validateNonNegativeNumber(_ value: Any?, key: String) throws {
        guard let number = double(from: value) else {
            throw ValidationError.invalidValue(key: key, reason: "expected a non-negative number")
        }
        guard number >= 0 else {
            throw ValidationError.invalidValue(key: key, reason: "must be >= 0, got \(number)")
        }
    }

    // MARK: - Numeric coercion

    /// Extract an `Int` from a JSON value, rejecting booleans and non-integers.
    ///
    /// `JSONSerialization` and `[String: Any]` literals both bridge numbers to
    /// `NSNumber`, and `Bool` bridges to `NSNumber` too — so we explicitly reject
    /// the boolean object type (otherwise `true`/`false` would read as `1`/`0`).
    private static func integer(from value: Any?) -> Int? {
        guard let value, !isBool(value) else { return nil }
        if let int = value as? Int { return int }
        // An NSNumber that is not integral (e.g. 1.5) must not pass as an Int.
        if let number = value as? NSNumber {
            let asInt = number.intValue
            return NSNumber(value: asInt) == number ? asInt : nil
        }
        return nil
    }

    /// Extract a `Double` from a JSON value, rejecting booleans.
    private static func double(from value: Any?) -> Double? {
        guard let value, !isBool(value) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// True when `value` is a boolean bridged to `NSNumber`/`CFBoolean`.
    ///
    /// `Bool`, `Int`, and `Double` all bridge to `NSNumber`, so a plain
    /// `value as? Bool` succeeds for `1`/`0` too. Comparing the CoreFoundation
    /// type id against `CFBoolean`'s distinguishes a genuine boolean (which JSON
    /// `true`/`false` decodes to) from a numeric `1`/`0`, so `true`/`false` never
    /// slip through the `tokens` / `cost_usd` numeric coercions above.
    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
