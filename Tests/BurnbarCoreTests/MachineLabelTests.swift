import XCTest
@testable import BurnbarCore

final class MachineLabelTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "MachineLabelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsToSystemComputerName() {
        let defaults = freshDefaults()
        let store = MachineLabel(defaults: defaults, systemName: { "Andy's MacBook Pro" })
        XCTAssertEqual(store.label, "Andy's MacBook Pro")
        XCTAssertNil(store.storedOverride)
    }

    func testOverrideWinsOverSystemName() {
        let defaults = freshDefaults()
        let store = MachineLabel(defaults: defaults, systemName: { "Andy's MacBook Pro" })
        store.rename(to: "Work Laptop")
        XCTAssertEqual(store.label, "Work Laptop")
        XCTAssertEqual(store.storedOverride, "Work Laptop")
    }

    func testOverridePersistsAcrossFreshStoreInstance() {
        let defaults = freshDefaults()
        let systemName: @Sendable () -> String = { "Andy's MacBook Pro" }
        MachineLabel(defaults: defaults, systemName: systemName).rename(to: "Studio Mac")

        // A brand-new store reading the same defaults sees the persisted override.
        let reloaded = MachineLabel(defaults: defaults, systemName: systemName)
        XCTAssertEqual(reloaded.label, "Studio Mac")
        XCTAssertEqual(defaults.string(forKey: MachineLabel.defaultsKey), "Studio Mac")
    }

    func testRenameTrimsWhitespace() {
        let defaults = freshDefaults()
        let store = MachineLabel(defaults: defaults, systemName: { "Default" })
        store.rename(to: "  Spaced Out \n")
        XCTAssertEqual(store.label, "Spaced Out")
        XCTAssertEqual(defaults.string(forKey: MachineLabel.defaultsKey), "Spaced Out")
    }

    func testClearingOverrideRevertsToSystemDefault() {
        let defaults = freshDefaults()
        let store = MachineLabel(defaults: defaults, systemName: { "System Name" })
        store.rename(to: "Custom")
        XCTAssertEqual(store.label, "Custom")

        store.rename(to: "   ")
        XCTAssertEqual(store.label, "System Name")
        XCTAssertNil(store.storedOverride)
        XCTAssertNil(defaults.string(forKey: MachineLabel.defaultsKey))
    }

    func testEmptyRenameRevertsToSystemDefault() {
        let defaults = freshDefaults()
        let store = MachineLabel(defaults: defaults, systemName: { "System Name" })
        store.rename(to: "Custom")
        store.rename(to: "")
        XCTAssertEqual(store.label, "System Name")
        XCTAssertNil(store.storedOverride)
    }

    func testSystemComputerNameIsNonEmpty() {
        // The real default source resolves to a usable, non-empty string on the
        // host (localizedName or hostName fallback).
        XCTAssertFalse(MachineLabel.systemComputerName().isEmpty)
    }
}
