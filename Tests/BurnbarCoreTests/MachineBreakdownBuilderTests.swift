import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``MachineBreakdownBuilder`` to assert 2.4.3's per-machine panel
/// contract: each machine's today burn ($ + tokens) is summed from its records,
/// the top model is the day's highest-token model, rows sort by today's burn
/// descending, the local Mac is flagged, stale machines are flagged, and labels
/// fall back to the raw id. Pinned clock + pinned $1/MTok rate keep every figure
/// deterministic, independent of the host clock and the live pricing table.
///
/// The DoD ("renders correctly for 1–5 machines") is exercised directly: the
/// 1-machine and 5-machine builds are asserted end-to-end.
final class MachineBreakdownBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// Fixed UTC calendar so "today" bucketing is independent of the host timezone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = ISO8601DateFormatter().date(from: "2026-05-30T12:00:00Z")!
    private let today = "2026-05-30"
    private let yesterday = "2026-05-29"

    /// A builder pinned to $1/MTok input so cost is predictable: `cost == inputTokens
    /// / 1_000_000`. The real pricing table never affects the assertions.
    private func builder() -> MachineBreakdownBuilder {
        let pricing = ModelPricing(
            inputPerMTok: 1,
            outputPerMTok: 0,
            cacheReadPerMTok: 0,
            cacheCreatePerMTok: 0
        )
        return MachineBreakdownBuilder(
            calculator: CostCalculator(pricingLookup: { _ in pricing }),
            aggregator: TimeWindowAggregator(calendar: calendar)
        )
    }

    private func context(
        thisMachineID: String = "local",
        labels: [String: String] = [:],
        staleIDs: Set<String> = []
    ) -> MachineBreakdownBuilder.Context {
        MachineBreakdownBuilder.Context(
            thisMachineID: thisMachineID,
            labels: labels,
            staleIDs: staleIDs,
            now: now
        )
    }

    private func claude(day: String, model: String = "claude-opus-4-7", input: Int) -> UsageRecord {
        UsageRecord(provider: .claude, model: model, day: day, inputTokens: input)
    }

    // MARK: - DoD: 1 machine

    /// A single machine renders one row carrying its today burn ($ + tokens) and
    /// top model, flagged as this Mac and labelled from the provided map.
    func testSingleMachineRow() {
        let rows = builder().rows(
            from: ["local": [claude(day: today, input: 1_500_000)]],
            context: context(labels: ["local": "MacBook Pro"])
        )

        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.id, "local")
        XCTAssertEqual(row.label, "MacBook Pro")
        XCTAssertTrue(row.isThisMac)
        XCTAssertFalse(row.isStale)
        XCTAssertEqual(row.todayTokens, 1_500_000)
        XCTAssertEqual(row.todayCostUSD, 1.5, accuracy: 0.0001)
        XCTAssertEqual(row.topModel, "claude-opus-4-7")
    }

    // MARK: - DoD: 5 machines

    /// Five machines all render, sorted by today's burn descending, each with its
    /// own summed today total — the upper end of the 1–5 range the DoD names.
    func testFiveMachinesSortedByBurnDescending() {
        let byMachine: [String: [UsageRecord]] = [
            "m1": [claude(day: today, input: 100)],
            "m2": [claude(day: today, input: 500)],
            "m3": [claude(day: today, input: 300)],
            "m4": [claude(day: today, input: 900)],
            "m5": [claude(day: today, input: 50)]
        ]

        let rows = builder().rows(from: byMachine, context: context(thisMachineID: "m1"))

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.id), ["m4", "m2", "m3", "m1", "m5"])
        XCTAssertEqual(rows.map(\.todayTokens), [900, 500, 300, 100, 50])
    }

    // MARK: - Today window only

    /// Only today's records count toward the row burn; yesterday's are excluded by
    /// the aggregator's today window.
    func testOnlyTodayCountsTowardBurn() {
        let rows = builder().rows(
            from: ["local": [
                claude(day: today, input: 200),
                claude(day: yesterday, input: 9999)
            ]],
            context: context()
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].todayTokens, 200)
    }

    // MARK: - Top model

    /// The top model is the one with the most tokens *today*, summed across that
    /// machine's records, not merely the first seen.
    func testTopModelIsHighestTokenModelToday() {
        let rows = builder().rows(
            from: ["local": [
                claude(day: today, model: "claude-haiku-4", input: 100),
                claude(day: today, model: "claude-opus-4-7", input: 400),
                claude(day: today, model: "claude-haiku-4", input: 100)
            ]],
            context: context()
        )

        XCTAssertEqual(rows[0].topModel, "claude-opus-4-7")
        XCTAssertEqual(rows[0].todayTokens, 600)
    }

    /// A tie on token count resolves deterministically to the lexicographically
    /// smallest model id, so the pick never depends on dictionary order.
    func testTopModelTieBreaksOnModelID() {
        let rows = builder().rows(
            from: ["local": [
                claude(day: today, model: "zeta", input: 100),
                claude(day: today, model: "alpha", input: 100)
            ]],
            context: context()
        )

        XCTAssertEqual(rows[0].topModel, "alpha")
    }

    /// A machine with no usage today has a nil top model and zero burn (the
    /// stale / quiet case) — never a crash or fabricated model.
    func testNoUsageTodayHasNilTopModelAndZeroBurn() {
        let rows = builder().rows(
            from: ["local": [claude(day: yesterday, input: 500)]],
            context: context()
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].topModel)
        XCTAssertEqual(rows[0].todayTokens, 0)
        XCTAssertEqual(rows[0].todayCostUSD, 0, accuracy: 0.0001)
    }

    // MARK: - Flags & labels

    /// Stale ids are flagged on their rows (the panel dims + suffixes them); others
    /// are not.
    func testStaleFlagging() {
        let rows = builder().rows(
            from: [
                "fresh": [claude(day: today, input: 300)],
                "old": [claude(day: today, input: 100)]
            ],
            context: context(thisMachineID: "fresh", staleIDs: ["old"])
        )

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["old"]?.isStale, true)
        XCTAssertEqual(byID["fresh"]?.isStale, false)
    }

    /// Only the matching id is flagged "This Mac".
    func testThisMacFlag() {
        let rows = builder().rows(
            from: [
                "local": [claude(day: today, input: 100)],
                "remote": [claude(day: today, input: 200)]
            ],
            context: context(thisMachineID: "local")
        )

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["local"]?.isThisMac, true)
        XCTAssertEqual(byID["remote"]?.isThisMac, false)
    }

    /// A machine absent from the label map falls back to its raw id as the label
    /// (the view then shows the truncated `shortID`).
    func testLabelFallsBackToID() {
        let rows = builder().rows(
            from: ["a1b2c3d4e5f60718": [claude(day: today, input: 100)]],
            context: context(thisMachineID: "other", labels: [:])
        )

        XCTAssertEqual(rows[0].label, "a1b2c3d4e5f60718")
        XCTAssertEqual(rows[0].shortID, "a1b2c3d4")
    }

    // MARK: - Empty

    /// An empty `byMachine` map yields no rows (iCloud-empty / This-Mac case).
    func testEmptyMapYieldsNoRows() {
        XCTAssertTrue(builder().rows(from: [:], context: context()).isEmpty)
    }

    // MARK: - Sort stability on equal burn

    /// When two machines have equal today burn (e.g. both zero), the tiebreak is
    /// deterministic: this Mac first, then label case-insensitively — so the panel
    /// order never flickers between reloads.
    func testEqualBurnTieBreaksThisMacThenLabel() {
        let byMachine: [String: [UsageRecord]] = [
            "z": [claude(day: yesterday, input: 1)],
            "a": [claude(day: yesterday, input: 1)],
            "me": [claude(day: yesterday, input: 1)]
        ]

        let rows = builder().rows(
            from: byMachine,
            context: context(
                thisMachineID: "me",
                labels: ["z": "Zed", "a": "Alpha", "me": "Mine"]
            )
        )

        // All zero burn → this Mac first, then by label (Alpha < Zed).
        XCTAssertEqual(rows.map(\.id), ["me", "a", "z"])
    }
}
