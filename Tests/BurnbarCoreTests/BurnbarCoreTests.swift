import XCTest
@testable import BurnbarCore

/// Smoke test proving the core module links and runs under `xcodebuild test`.
/// Real parser/cost tests with fixtures arrive in Epics 1.2.5 / 1.3.4 / 1.4.
final class BurnbarCoreTests: XCTestCase {
    func testCoreVersionMatchesMarketingVersion() {
        XCTAssertEqual(BurnbarCore.version, "0.1.0")
    }
}
