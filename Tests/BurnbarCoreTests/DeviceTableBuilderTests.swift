import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``DeviceTableBuilder`` to assert 2.4.4's table-assembly contract: per
/// machine today + all-time burn is summed from its records, the local Mac is
/// flagged and labelled from `MachineLabel`, other machines take the registry
/// label, the hidden flag is surfaced, the short id is the first 8 chars, and rows
/// sort with this Mac first.
final class DeviceTableBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed calendar/clock so the "today" window is deterministic. UTC keeps
    /// the day-string bucketing independent of the host timezone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = ISO8601DateFormatter().date(from: "2026-05-30T12:00:00Z")!

    /// A builder with a pinned $1/MTok-input rate so cost is predictable and the
    /// real pricing table never affects the assertions.
    private func builder() -> DeviceTableBuilder {
        let pricing = ModelPricing(
            inputPerMTok: 1,
            outputPerMTok: 0,
            cacheReadPerMTok: 0,
            cacheCreatePerMTok: 0
        )
        return DeviceTableBuilder(
            calculator: CostCalculator(pricingLookup: { _ in pricing }),
            aggregator: TimeWindowAggregator(calendar: calendar)
        )
    }

    /// A build context with sensible defaults, overridable per test.
    private func context(
        thisMachineID: String = "local",
        thisMachineLabel: String = "Local",
        registryLabels: [String: String] = [:],
        hiddenIDs: Set<String> = []
    ) -> DeviceTableBuilder.Context {
        DeviceTableBuilder.Context(
            thisMachineID: thisMachineID,
            thisMachineLabel: thisMachineLabel,
            registryLabels: registryLabels,
            hiddenIDs: hiddenIDs,
            now: now
        )
    }

    private func claude(day: String, input: Int) -> UsageRecord {
        UsageRecord(provider: .claude, model: "claude-opus-4-7", day: day, inputTokens: input)
    }

    // MARK: - Tests

    func testSumsTodayAndTotalBurnPerMachine() throws {
        let machine = MachineUsage(
            machineID: "abcdef0123456789",
            records: [
                claude(day: "2026-05-30", input: 1_000_000), // today
                claude(day: "2026-05-29", input: 2_000_000) // earlier
            ]
        )
        let rows = builder().rows(
            from: [machine],
            context: context(thisMachineID: "abcdef0123456789", thisMachineLabel: "My Mac")
        )

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.todayTokens, 1_000_000)
        XCTAssertEqual(row.todayCostUSD, 1.0, accuracy: 0.0001)
        XCTAssertEqual(row.totalTokens, 3_000_000)
        XCTAssertEqual(row.totalCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertEqual(row.lastRecordDay, "2026-05-30")
    }

    func testThisMacFlaggedAndLabelledFromMachineLabel() throws {
        let machine = MachineUsage(machineID: "local-id", records: [claude(day: "2026-05-30", input: 5)])
        let rows = builder().rows(
            from: [machine],
            context: context(
                thisMachineID: "local-id",
                thisMachineLabel: "Studio",
                registryLabels: ["local-id": "stale registry label"]
            )
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isThisMac)
        // The MachineLabel override wins over the registry label for the local row.
        XCTAssertEqual(row.label, "Studio")
    }

    func testOtherMachineTakesRegistryLabelThenFallsBackToID() {
        let labelled = MachineUsage(machineID: "remote-1", records: [])
        let unlabelled = MachineUsage(machineID: "remote-2", records: [])
        let rows = builder().rows(
            from: [labelled, unlabelled],
            context: context(registryLabels: ["remote-1": "Work Laptop"])
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["remote-1"]?.label, "Work Laptop")
        XCTAssertEqual(byID["remote-2"]?.label, "remote-2")
        XCTAssertFalse(byID["remote-1"]?.isThisMac ?? true)
    }

    func testHiddenFlagSurfaced() throws {
        let machine = MachineUsage(machineID: "hidden-mac", records: [])
        let rows = builder().rows(
            from: [machine],
            context: context(hiddenIDs: ["hidden-mac"])
        )
        XCTAssertTrue(try XCTUnwrap(rows.first).isHidden)
    }

    func testShortIDIsFirstEightChars() {
        let summary = DeviceSummary(
            id: "abcdef0123456789",
            label: "x",
            isThisMac: false,
            isHidden: false,
            todayTokens: 0,
            todayCostUSD: 0,
            totalTokens: 0,
            totalCostUSD: 0,
            lastRecordDay: nil
        )
        XCTAssertEqual(summary.shortID, "abcdef01")
    }

    func testRowsSortThisMacFirstThenByLabel() {
        let machines = [
            MachineUsage(machineID: "id-zed", records: []),
            MachineUsage(machineID: "id-this", records: []),
            MachineUsage(machineID: "id-abe", records: [])
        ]
        let rows = builder().rows(
            from: machines,
            context: context(
                thisMachineID: "id-this",
                thisMachineLabel: "Zeta Local", // late alphabetically, but still first
                registryLabels: ["id-zed": "Beta", "id-abe": "Alpha"]
            )
        )
        XCTAssertEqual(rows.map(\.id), ["id-this", "id-abe", "id-zed"])
        XCTAssertTrue(rows.first?.isThisMac ?? false)
    }

    func testRendersOneToFiveMachines() {
        for count in 1 ... 5 {
            let machines = (0 ..< count).map { index in
                MachineUsage(
                    machineID: "machine-\(index)",
                    records: [claude(day: "2026-05-30", input: 10)]
                )
            }
            let rows = builder().rows(
                from: machines,
                context: context(thisMachineID: "machine-0", thisMachineLabel: "Primary")
            )
            XCTAssertEqual(rows.count, count, "table should render \(count) machine(s)")
        }
    }

    func testMachineWithNoRecordsHasZeroBurnAndNilDay() throws {
        let machine = MachineUsage(machineID: "idle", records: [])
        let row = try XCTUnwrap(
            builder().rows(
                from: [machine],
                context: context(thisMachineID: "other", thisMachineLabel: "Other")
            ).first
        )
        XCTAssertEqual(row.todayTokens, 0)
        XCTAssertEqual(row.totalTokens, 0)
        XCTAssertNil(row.lastRecordDay)
    }
}
