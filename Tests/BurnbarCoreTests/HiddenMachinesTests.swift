import XCTest
@testable import BurnbarCore

/// Drives ``HiddenMachines`` to assert 2.4.4's hide behaviour: hiding persists,
/// hidden machines are excluded from the visible (combined-view) subset, unhiding
/// reverses it, and the set survives a fresh store instance over the same defaults.
final class HiddenMachinesTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "HiddenMachinesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEmptyByDefault() {
        let store = HiddenMachines(defaults: freshDefaults())
        XCTAssertTrue(store.hiddenIDs().isEmpty)
        XCTAssertFalse(store.isHidden("anything"))
    }

    func testHidePersistsAndIsIdempotent() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.hide("studio")
        XCTAssertTrue(store.isHidden("studio"))
        XCTAssertEqual(store.hiddenIDs(), ["studio"])

        // Hiding again is a no-op — the set stays a singleton.
        store.hide("studio")
        XCTAssertEqual(store.hiddenIDs(), ["studio"])
    }

    func testUnhideRemovesFromSet() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.hide("laptop")
        store.unhide("laptop")
        XCTAssertFalse(store.isHidden("laptop"))
        XCTAssertTrue(store.hiddenIDs().isEmpty)
    }

    func testUnhideUnknownIsNoOp() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.unhide("ghost")
        XCTAssertTrue(store.hiddenIDs().isEmpty)
    }

    func testToggleFlipsAndReportsNewState() {
        let store = HiddenMachines(defaults: freshDefaults())
        XCTAssertTrue(store.toggle("m1"), "first toggle hides")
        XCTAssertTrue(store.isHidden("m1"))
        XCTAssertFalse(store.toggle("m1"), "second toggle unhides")
        XCTAssertFalse(store.isHidden("m1"))
    }

    func testVisibleExcludesHiddenPreservingOrder() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.hide("beta")
        let visible = store.visible(from: ["alpha", "beta", "gamma"])
        XCTAssertEqual(visible, ["alpha", "gamma"])
    }

    func testForgetDropsFromHiddenSet() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.hide("retired")
        store.forget("retired")
        XCTAssertFalse(store.isHidden("retired"))
        XCTAssertTrue(store.hiddenIDs().isEmpty)
    }

    func testMultipleHiddenTrackedIndependently() {
        let store = HiddenMachines(defaults: freshDefaults())
        store.hide("zeta")
        store.hide("alpha")
        store.hide("mid")
        XCTAssertEqual(store.hiddenIDs(), ["alpha", "mid", "zeta"])

        store.unhide("mid")
        XCTAssertEqual(store.hiddenIDs(), ["alpha", "zeta"])
        XCTAssertEqual(store.visible(from: ["alpha", "mid", "zeta"]), ["mid"])
    }

    func testHiddenSetPersistsAcrossFreshInstance() {
        let defaults = freshDefaults()
        let writer = HiddenMachines(defaults: defaults)
        writer.hide("persisted")

        let reloaded = HiddenMachines(defaults: defaults)
        XCTAssertTrue(reloaded.isHidden("persisted"))
        XCTAssertEqual(reloaded.hiddenIDs(), ["persisted"])
    }

    func testCorruptStoredValueYieldsEmptySet() {
        let defaults = freshDefaults()
        // A non-[String] value under the key (e.g. a stray number array).
        defaults.set([1, 2, 3], forKey: HiddenMachines.defaultsKey)
        let store = HiddenMachines(defaults: defaults)
        XCTAssertTrue(store.hiddenIDs().isEmpty)
    }
}
