import XCTest
@testable import BurnbarCore

/// Tests for the popover's "N Macs syncing" badge logic (Epic 2.4.2).
///
/// `SyncingBadge` is the pure piece behind the All-Macs badge: it maps a machine
/// count to the exact English string the badge shows, with singular/plural
/// handling. These guard the wording and — the core of the ticket's DoD — that the
/// count the badge reports equals the number of machines the reconciler summed into
/// the combined total (so the badge and the displayed burn can never disagree).
final class SyncingBadgeTests: XCTestCase {
    // MARK: - Singular / plural wording

    /// Two or more machines use the plural "Macs" with the count.
    func testPluralForMultipleMachines() {
        XCTAssertEqual(SyncingBadge.text(machineCount: 3), "3 Macs syncing")
        XCTAssertEqual(SyncingBadge.text(machineCount: 12), "12 Macs syncing")
    }

    /// Exactly one machine uses the singular "Mac".
    func testSingularForOneMachine() {
        XCTAssertEqual(SyncingBadge.text(machineCount: 1), "1 Mac syncing")
    }

    /// Zero machines (combined view resolved but no rollups found) reads "No Macs".
    func testZeroMachines() {
        XCTAssertEqual(SyncingBadge.text(machineCount: 0), "No Macs syncing")
    }

    /// A negative count (defensive guard) is clamped to the zero phrasing rather
    /// than producing "-1 Macs syncing".
    func testNegativeCountClampsToZero() {
        XCTAssertEqual(SyncingBadge.text(machineCount: -5), "No Macs syncing")
    }

    // MARK: - DoD: count == machines reconciled into the combined total

    /// The badge count is `ReconciledUsage.byMachine.count`, and that equals the
    /// number of distinct machines whose records were summed into `combined`. This
    /// mirrors how `UsageStore.loadAllMacs` derives the count, so the badge and the
    /// summed burn it labels are guaranteed to agree.
    func testBadgeCountMatchesReconciledMachineCount() {
        let byMachine: [String: [UsageRecord]] = [
            "mac-a": [record(input: 100)],
            "mac-b": [record(input: 200)],
            "mac-c": [record(input: 300)],
        ]

        let reconciled = Reconciler().merge(byMachine)

        // The count the badge would show.
        XCTAssertEqual(reconciled.byMachine.count, 3)
        XCTAssertEqual(SyncingBadge.text(machineCount: reconciled.byMachine.count), "3 Macs syncing")

        // And it equals the number of machines actually folded into the total: the
        // combined input tokens equal the sum of every per-machine input total.
        let combinedInput = reconciled.combined.reduce(0) { $0 + $1.inputTokens }
        let perMachineInput = byMachine.values.flatMap { $0 }.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(combinedInput, perMachineInput, "combined burn must equal the sum of per-machine burn")
    }

    /// A single contributing machine yields a count of 1 and the singular label.
    func testSingleMachineReconcilesToSingularBadge() {
        let reconciled = Reconciler().merge(["only-mac": [record(input: 42)]])
        XCTAssertEqual(SyncingBadge.text(machineCount: reconciled.byMachine.count), "1 Mac syncing")
    }

    /// An empty combined view (no rollups) yields a count of 0 and the "No Macs"
    /// label — the iCloud-empty / unavailable case the All-Macs loader hits.
    func testEmptyReconciliationReadsAsNoMacs() {
        let reconciled = Reconciler().merge([:])
        XCTAssertEqual(reconciled.byMachine.count, 0)
        XCTAssertEqual(SyncingBadge.text(machineCount: reconciled.byMachine.count), "No Macs syncing")
    }

    // MARK: - Helpers

    private func record(input: Int) -> UsageRecord {
        UsageRecord(
            provider: .claude,
            model: "claude-sonnet-4",
            day: "2026-05-30",
            inputTokens: input,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            costUSD: nil
        )
    }
}
