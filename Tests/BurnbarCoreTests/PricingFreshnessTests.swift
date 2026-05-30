import XCTest
@testable import BurnbarCore

/// Guardrail for Epic 1.4.4 ("Pricing freshness check").
///
/// Pricing rates drift over time, and a stale `PricingTable.swift` silently
/// produces wrong dollar figures. This test makes staleness loud: it fails in CI
/// when the pricing snapshot date is more than 90 days before "now", with a
/// message instructing the maintainer to update `PricingTable.swift`.
final class PricingFreshnessTests: XCTestCase {
    /// Maximum age, in days, before the pricing snapshot is considered stale.
    /// Mirrors CLAUDE.md "Pricing freshness": ">90 days stale".
    private let maxAgeDays = 90

    /// Fails if `PricingTable.snapshotDateValue` is more than `maxAgeDays` old.
    ///
    /// The failure message must contain the literal phrase "update PricingTable.swift"
    /// (Definition of Done) so the fix is obvious from CI output alone.
    func testPricingTableIsFresh() {
        let snapshot = PricingTable.snapshotDateValue

        // UTC calendar so the day count is timezone-stable and matches how
        // `snapshotDateValue` is parsed (UTC midnight).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let ageDays = calendar.dateComponents([.day], from: snapshot, to: Date()).day ?? .max

        XCTAssertLessThanOrEqual(
            ageDays,
            maxAgeDays,
            """
            PricingTable is \(ageDays) days stale (snapshot \(PricingTable.snapshotDate), max \(maxAgeDays)). \
            Re-verify per-model rates against the official Anthropic/OpenAI pricing pages and update PricingTable.swift \
            (bump both the `Pricing snapshot:` comment and `snapshotDate`).
            """
        )
    }

    /// The snapshot must not be dated in the future — a future date would mask a
    /// genuinely stale table by making `ageDays` negative (and thus "fresh").
    func testPricingSnapshotIsNotInTheFuture() {
        let snapshot = PricingTable.snapshotDateValue

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let ageDays = calendar.dateComponents([.day], from: snapshot, to: Date()).day ?? 0

        XCTAssertGreaterThanOrEqual(
            ageDays,
            0,
            "PricingTable.snapshotDate (\(PricingTable.snapshotDate)) is in the future; a future date hides staleness."
        )
    }

    /// `snapshotDateValue` must parse from the exact `snapshotDate` string (single
    /// source of truth) at UTC midnight, so the two stay in lock-step.
    func testSnapshotDateValueMatchesSnapshotString() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"

        let expected = formatter.date(from: PricingTable.snapshotDate)
        XCTAssertEqual(
            PricingTable.snapshotDateValue,
            expected,
            "snapshotDateValue must equal snapshotDate parsed as UTC YYYY-MM-DD"
        )
    }
}
