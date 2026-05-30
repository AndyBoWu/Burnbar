import XCTest
@testable import BurnbarCore

final class MachineRegistryTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "MachineRegistryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    func testUnknownMachineLookupReturnsNil() {
        let registry = MachineRegistry(defaults: freshDefaults())
        XCTAssertNil(registry.machine(id: "never-seen"))
        XCTAssertTrue(registry.all().isEmpty)
    }

    func testNewMachineAutoAddedWithDefaultLabel() {
        let registry = MachineRegistry(
            defaults: freshDefaults(),
            defaultLabel: { "default-for-\($0)" }
        )
        let seen = date("2026-05-29T00:00:00Z")
        registry.upsert(machineID: "abc123", lastSeen: seen)

        let entry = registry.machine(id: "abc123")
        XCTAssertEqual(entry?.id, "abc123")
        XCTAssertEqual(entry?.label, "default-for-abc123")
        XCTAssertEqual(entry?.lastSeen, seen)
    }

    func testDefaultLabelDefaultsToMachineID() {
        // With no injected default-label source, the id itself is the label.
        let registry = MachineRegistry(defaults: freshDefaults())
        registry.upsert(machineID: "raw-id", lastSeen: date("2026-05-29T00:00:00Z"))
        XCTAssertEqual(registry.machine(id: "raw-id")?.label, "raw-id")
    }

    func testReUpsertAdvancesLastSeenButKeepsDefaultLabel() {
        let registry = MachineRegistry(
            defaults: freshDefaults(),
            defaultLabel: { _ in "default" }
        )
        let first = date("2026-05-28T00:00:00Z")
        let later = date("2026-05-30T12:00:00Z")
        registry.upsert(machineID: "m1", lastSeen: first)
        registry.upsert(machineID: "m1", lastSeen: later)

        let entry = registry.machine(id: "m1")
        XCTAssertEqual(entry?.lastSeen, later)
        XCTAssertEqual(entry?.label, "default")
    }

    func testRenamePreservedAcrossSubsequentUpsert() {
        // The load-bearing DoD: a user rename must survive the reader
        // re-surfacing the machine with its default label.
        let registry = MachineRegistry(
            defaults: freshDefaults(),
            defaultLabel: { _ in "Default Name" }
        )
        registry.upsert(machineID: "studio", lastSeen: date("2026-05-28T00:00:00Z"))
        registry.rename(machineID: "studio", to: "Studio Mac")
        XCTAssertEqual(registry.machine(id: "studio")?.label, "Studio Mac")

        // A re-sighting (which would supply the default label for a new machine)
        // must NOT clobber the user's rename — only lastSeen advances.
        let later = date("2026-05-30T00:00:00Z")
        registry.upsert(machineID: "studio", lastSeen: later)

        let entry = registry.machine(id: "studio")
        XCTAssertEqual(entry?.label, "Studio Mac")
        XCTAssertEqual(entry?.lastSeen, later)
    }

    func testRenameUnknownMachineIsNoOp() {
        let registry = MachineRegistry(defaults: freshDefaults())
        registry.rename(machineID: "ghost", to: "Should Not Exist")
        XCTAssertNil(registry.machine(id: "ghost"))
        XCTAssertTrue(registry.all().isEmpty)
    }

    func testMultipleMachinesTrackedIndependentlyAndSortedByID() {
        let registry = MachineRegistry(
            defaults: freshDefaults(),
            defaultLabel: { "label-\($0)" }
        )
        registry.upsert(machineID: "zeta", lastSeen: date("2026-05-29T00:00:00Z"))
        registry.upsert(machineID: "alpha", lastSeen: date("2026-05-28T00:00:00Z"))
        registry.upsert(machineID: "mid", lastSeen: date("2026-05-27T00:00:00Z"))
        registry.rename(machineID: "alpha", to: "First Mac")

        let all = registry.all()
        XCTAssertEqual(all.map(\.id), ["alpha", "mid", "zeta"])
        XCTAssertEqual(all.first?.label, "First Mac")
        XCTAssertEqual(registry.machine(id: "zeta")?.label, "label-zeta")
        XCTAssertEqual(registry.machine(id: "mid")?.label, "label-mid")
    }

    func testTablePersistsAcrossFreshRegistryInstance() {
        let defaults = freshDefaults()
        let seen = date("2026-05-29T00:00:00Z")
        let writer = MachineRegistry(defaults: defaults, defaultLabel: { _ in "Default" })
        writer.upsert(machineID: "persisted", lastSeen: seen)
        writer.rename(machineID: "persisted", to: "Renamed")

        // A brand-new registry over the same defaults sees the persisted table.
        let reloaded = MachineRegistry(defaults: defaults, defaultLabel: { _ in "Default" })
        let entry = reloaded.machine(id: "persisted")
        XCTAssertEqual(entry?.label, "Renamed")
        XCTAssertEqual(entry?.lastSeen, seen)
        XCTAssertEqual(reloaded.all().count, 1)
    }

    func testCorruptStoredDataYieldsEmptyTable() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: MachineRegistry.defaultsKey)
        let registry = MachineRegistry(defaults: defaults)
        XCTAssertTrue(registry.all().isEmpty)
        XCTAssertNil(registry.machine(id: "anything"))
    }

    func testEntryRoundTripsThroughCodable() throws {
        let entry = MachineIdentityEntry(
            id: "abc",
            label: "My Mac",
            lastSeen: date("2026-05-29T08:30:00Z")
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MachineIdentityEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}
