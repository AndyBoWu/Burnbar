import XCTest
@testable import BurnbarCore

/// Tests for the popover's view-mode model (Epic 2.4.1).
///
/// `ViewMode` is the pure piece behind the "This Mac | All Macs" segmented
/// control: the popover binds to it and persists the raw value under
/// `ViewMode.storageKey`, while `UsageStore` reads the same key to choose its data
/// source. These guard the case set, English labels, the default, and — the core
/// of the ticket's DoD — that the choice round-trips through `UserDefaults`.
final class ViewModeTests: XCTestCase {
    /// Exactly two modes, in display order: This Mac, then All Macs.
    func testTwoCasesInOrder() {
        XCTAssertEqual(ViewMode.allCases, [.thisMac, .allMacs])
    }

    /// English titles match the "This Mac | All Macs" spec.
    func testTitles() {
        XCTAssertEqual(ViewMode.thisMac.title, "This Mac")
        XCTAssertEqual(ViewMode.allMacs.title, "All Macs")
    }

    /// Raw values are the stable storage tokens — guard against an accidental
    /// rename that would silently reset a user's persisted choice on upgrade.
    func testRawValuesAreStableStorageTokens() {
        XCTAssertEqual(ViewMode.thisMac.rawValue, "thisMac")
        XCTAssertEqual(ViewMode.allMacs.rawValue, "allMacs")
    }

    /// The persistence key matches the ticket's `popover.viewMode` slot.
    func testStorageKey() {
        XCTAssertEqual(ViewMode.storageKey, "popover.viewMode")
    }

    /// A fresh install (no stored value) defaults to this machine only, so it
    /// behaves exactly as it did pre-2.4 until the user opts into the combined view.
    func testDefaultIsThisMac() {
        XCTAssertEqual(ViewMode.default, .thisMac)
    }

    /// `id` is the raw value, so SwiftUI `ForEach`/`.tag` identity is stable.
    func testIdentityIsRawValue() {
        for mode in ViewMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    // MARK: - UserDefaults round-trip (the 2.4.1 DoD)

    /// Every mode survives a write→read cycle through `UserDefaults` unchanged,
    /// using the same key + decoder the popover and `UsageStore` share.
    func testModeRoundTripsThroughUserDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        for mode in ViewMode.allCases {
            defaults.set(mode.rawValue, forKey: ViewMode.storageKey)
            let restored = ViewMode.fromStorage(defaults.string(forKey: ViewMode.storageKey))
            XCTAssertEqual(restored, mode, "\(mode) did not round-trip through UserDefaults")
        }
    }

    /// An absent key decodes to the default (this is the fresh-install path).
    func testAbsentKeyDecodesToDefault() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(defaults.string(forKey: ViewMode.storageKey))
        XCTAssertEqual(ViewMode.fromStorage(defaults.string(forKey: ViewMode.storageKey)), .default)
    }

    /// An unrecognized stored token (e.g. written by a newer build) decodes to the
    /// default rather than crashing or returning `nil`.
    func testUnknownStoredValueDecodesToDefault() {
        XCTAssertEqual(ViewMode.fromStorage("someFutureMode"), .default)
        XCTAssertEqual(ViewMode.fromStorage(nil), .default)
    }

    // MARK: - Helpers

    /// A throwaway `UserDefaults` suite so tests never touch the real domain;
    /// cleared on creation for isolation.
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "xyz.andybowu.Burnbar.tests.viewmode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
