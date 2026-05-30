import XCTest
@testable import BurnbarCore

final class MachineIdentityTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "MachineIdentityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testKnownUUIDMapsToExpectedTruncatedHash() {
        // first 16 hex chars of SHA-256("ABCDEF01-2345-6789-ABCD-EF0123456789")
        XCTAssertEqual(
            MachineIdentity.machineID(fromUUID: "ABCDEF01-2345-6789-ABCD-EF0123456789"),
            "5c56c744211d5bac"
        )
    }

    func testIdIsSixteenLowercaseHexChars() {
        let id = MachineIdentity.machineID(fromUUID: "any-uuid")
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    func testCurrentIsStableAcrossCallsAndDerivedOnlyFromUUID() {
        let defaults = freshDefaults()
        let provider: () -> String? = { "ABCDEF01-2345-6789-ABCD-EF0123456789" }
        let first = MachineIdentity.current(defaults: defaults, hardwareUUID: provider)
        let second = MachineIdentity.current(defaults: defaults, hardwareUUID: provider)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "5c56c744211d5bac")
        XCTAssertEqual(defaults.string(forKey: MachineIdentity.defaultsKey), first)
    }

    func testCurrentReturnsCachedValueEvenIfUUIDChanges() {
        // Simulates "stable across reinstalls": once cached, a differing UUID
        // source does not change the persisted id.
        let defaults = freshDefaults()
        let cached = MachineIdentity.current(defaults: defaults, hardwareUUID: { "UUID-A" })
        let afterUUIDChange = MachineIdentity.current(defaults: defaults, hardwareUUID: { "UUID-B" })
        XCTAssertEqual(cached, afterUUIDChange)
    }

    func testMissingUUIDStillProducesStableId() {
        let first = MachineIdentity.machineID(fromUUID: nil)
        let second = MachineIdentity.machineID(fromUUID: nil)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 16)
    }
}
