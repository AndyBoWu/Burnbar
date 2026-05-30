import XCTest
@testable import BurnbarCore

/// Pure-logic tests for the menu bar "iCloud disabled" badge state (2.5.1).
/// Verifies the state flips between `.ok` and `.warning` as the resolved
/// ``ICloudLocation`` changes, and that the English-only copy is correct.
final class ICloudBadgeStateTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/x/Burnbar")

    // MARK: - Location → state mapping

    func testContainerLocationIsOK() {
        XCTAssertEqual(ICloudBadgeState(location: .container(dir)), .ok)
    }

    func testFallbackLocationIsOK() {
        XCTAssertEqual(ICloudBadgeState(location: .fallback(dir)), .ok)
    }

    func testUnavailableLocationIsWarning() {
        XCTAssertEqual(
            ICloudBadgeState(location: .unavailable(reason: "iCloud Drive disabled")),
            .warning
        )
    }

    /// The badge must flip back to OK once iCloud is re-enabled — the
    /// definition-of-done "clears when re-enabled" path.
    func testStateFlipsAvailableToDisabledAndBack() {
        let resolutions: [ICloudLocation] = [
            .container(dir), // enabled
            .unavailable(reason: "iCloud Drive disabled"), // user turns it off
            .fallback(dir) // user turns it back on
        ]
        let states = resolutions.map { ICloudBadgeState(location: $0) }
        XCTAssertEqual(states, [.ok, .warning, .ok])
    }

    // MARK: - ICloudLocation.isAvailable

    func testIsAvailableMatchesState() {
        XCTAssertTrue(ICloudLocation.container(dir).isAvailable)
        XCTAssertTrue(ICloudLocation.fallback(dir).isAvailable)
        XCTAssertFalse(ICloudLocation.unavailable(reason: "x").isAvailable)
    }

    // MARK: - Presentation accessors

    func testOKHasNoWarningAffordances() {
        let state = ICloudBadgeState.ok
        XCTAssertFalse(state.showsWarning)
        XCTAssertNil(state.tooltip)
        XCTAssertNil(state.accessibilityDescription)
    }

    func testWarningTooltipCopyIsEnglishAndExact() {
        let state = ICloudBadgeState.warning
        XCTAssertTrue(state.showsWarning)
        XCTAssertEqual(state.tooltip, "iCloud Drive disabled — sync off")
        XCTAssertEqual(state.accessibilityDescription, "Burnbar — iCloud Drive disabled, sync off")
    }
}
