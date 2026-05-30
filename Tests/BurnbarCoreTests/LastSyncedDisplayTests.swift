import XCTest
@testable import BurnbarCore

/// Tests for the Devices tab's "Last synced" formatter (2.1.3).
///
/// The Devices row is a placeholder until Epic 2.2 records real timestamps, so
/// these pin the `nil` placeholder and confirm a real `Date` renders a non-empty
/// relative description that 2.2.x can rely on.
final class LastSyncedDisplayTests: XCTestCase {
    /// A deterministic English (US) locale so the relative phrasing is stable
    /// regardless of the host machine's locale.
    private let enUS = Locale(identifier: "en_US")

    func testNilRendersNeverPlaceholder() {
        XCTAssertEqual(LastSyncedDisplay.text(for: nil), LastSyncedDisplay.neverSyncedText)
        XCTAssertEqual(LastSyncedDisplay.neverSyncedText, "Never")
    }

    func testRecentDateRendersRelativeDescription() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let text = LastSyncedDisplay.text(for: twoMinutesAgo, relativeTo: now, locale: enUS)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, LastSyncedDisplay.neverSyncedText)
        XCTAssertTrue(text.lowercased().contains("minute"), "Expected a minute-based phrase, got: \(text)")
    }

    func testNonNilNeverReturnsPlaceholder() {
        // Sanity: a real (non-nil) date never collapses to the placeholder text.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = LastSyncedDisplay.text(for: now, relativeTo: now, locale: enUS)
        XCTAssertNotEqual(text, LastSyncedDisplay.neverSyncedText)
    }
}
