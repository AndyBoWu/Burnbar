import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``Reconciler/merge(_:)`` to assert the Definition of Done: the combined
/// total equals the sum of every per-machine total, overlapping `(day, provider,
/// model)` keys collapse into one summed record, Codex's `nil` categories survive
/// the merge un-coerced, and a single machine passes through unchanged.
final class ReconcilerTests: XCTestCase {

    // MARK: - Builders

    private func claude(
        model: String = "claude-opus-4-7",
        day: String,
        input: Int,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheCreation: Int? = nil,
        cost: Double? = nil
    ) -> UsageRecord {
        UsageRecord(
            provider: .claude,
            model: model,
            day: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            costUSD: cost
        )
    }

    /// A Codex record carries only `inputTokens`; every other category is `nil`
    /// (docs/data-sources.md). Used to prove the merge never fabricates zeros.
    private func codex(model: String = "gpt-5", day: String, input: Int, cost: Double? = nil) -> UsageRecord {
        UsageRecord(
            provider: .codex,
            model: model,
            day: day,
            inputTokens: input,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            costUSD: cost
        )
    }

    /// Grand totals summed straight off a flat record list — the reference the
    /// combined view must match.
    private func totals(_ records: [UsageRecord]) -> Totals {
        records.reduce(into: Totals()) { acc, record in
            acc.input += record.inputTokens
            acc.output += record.outputTokens ?? 0
            acc.cacheRead += record.cacheReadTokens ?? 0
            acc.cacheCreation += record.cacheCreationTokens ?? 0
            acc.cost += record.costUSD ?? 0
        }
    }

    private struct Totals: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var cost = 0.0
    }

    // MARK: - DoD invariant: total == sum of per-machine totals

    func testCombinedTotalEqualsSumOfPerMachineTotals() {
        let byMachine: [String: [UsageRecord]] = [
            "mac-air": [
                claude(day: "2026-05-29", input: 100, output: 50, cacheRead: 10, cacheCreation: 5, cost: 0.20),
                codex(day: "2026-05-29", input: 300, cost: 0.30)
            ],
            "mac-studio": [
                claude(day: "2026-05-29", input: 200, output: 80, cacheRead: 20, cacheCreation: 7, cost: 0.40),
                claude(day: "2026-05-28", input: 90, output: 30, cost: 0.10)
            ]
        ]

        let result = Reconciler().merge(byMachine)

        // The invariant: every per-machine record's totals, summed flat, equal the
        // combined view's totals. Integer categories compare exactly; cost uses an
        // accuracy tolerance since float addition order differs between the flat
        // reference and the grouped sum.
        let flat = byMachine.values.flatMap(\.self)
        let combinedTotals = totals(result.combined)
        let flatTotals = totals(flat)
        XCTAssertEqual(combinedTotals.input, flatTotals.input)
        XCTAssertEqual(combinedTotals.output, flatTotals.output)
        XCTAssertEqual(combinedTotals.cacheRead, flatTotals.cacheRead)
        XCTAssertEqual(combinedTotals.cacheCreation, flatTotals.cacheCreation)
        XCTAssertEqual(combinedTotals.cost, flatTotals.cost, accuracy: 1e-9)

        // And the scalar grand totalTokens line up too.
        let combinedTokens = result.combined.reduce(0) { $0 + $1.totalTokens }
        let perMachineTokens = flat.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(combinedTokens, perMachineTokens)
    }

    // MARK: - Overlapping keys collapse into one summed record

    func testOverlappingKeysAcrossMachinesCollapseAndSum() {
        let byMachine: [String: [UsageRecord]] = [
            "a": [claude(day: "2026-05-29", input: 100, output: 40, cacheRead: 10, cacheCreation: 2, cost: 0.10)],
            "b": [claude(day: "2026-05-29", input: 200, output: 60, cacheRead: 30, cacheCreation: 8, cost: 0.25)]
        ]

        let result = Reconciler().merge(byMachine)

        XCTAssertEqual(result.combined.count, 1, "Same (day, provider, model) must collapse to one record")
        let merged = result.combined[0]
        XCTAssertEqual(merged.provider, .claude)
        XCTAssertEqual(merged.model, "claude-opus-4-7")
        XCTAssertEqual(merged.day, "2026-05-29")
        XCTAssertEqual(merged.inputTokens, 300)
        XCTAssertEqual(merged.outputTokens, 100)
        XCTAssertEqual(merged.cacheReadTokens, 40)
        XCTAssertEqual(merged.cacheCreationTokens, 10)
        XCTAssertEqual(merged.costUSD ?? 0, 0.35, accuracy: 1e-9)
    }

    func testDistinctKeysStayDistinct() {
        let byMachine: [String: [UsageRecord]] = [
            "a": [
                claude(day: "2026-05-29", input: 100),
                claude(model: "claude-sonnet-4-7", day: "2026-05-29", input: 50)
            ],
            "b": [
                claude(day: "2026-05-28", input: 70),
                codex(day: "2026-05-29", input: 300)
            ]
        ]

        let result = Reconciler().merge(byMachine)

        // 4 distinct (day, provider, model) keys → 4 combined records.
        XCTAssertEqual(result.combined.count, 4)
        let keys = Set(result.combined.map(\.id))
        XCTAssertEqual(keys.count, 4)
    }

    // MARK: - Codex nil categories are not coerced to zero

    func testCodexNilCategoriesSurviveMerge() {
        let byMachine: [String: [UsageRecord]] = [
            "a": [codex(day: "2026-05-29", input: 300)],
            "b": [codex(day: "2026-05-29", input: 200)]
        ]

        let result = Reconciler().merge(byMachine)

        XCTAssertEqual(result.combined.count, 1)
        let merged = result.combined[0]
        XCTAssertEqual(merged.inputTokens, 500)
        XCTAssertNil(merged.outputTokens, "Codex output stays nil, never 0")
        XCTAssertNil(merged.cacheReadTokens, "Codex cache-read stays nil, never 0")
        XCTAssertNil(merged.cacheCreationTokens, "Codex cache-creation stays nil, never 0")
        XCTAssertNil(merged.costUSD, "No cost reported → stays nil, never 0")
    }

    /// When one contributor reports a category and another leaves it `nil`, the
    /// sum reflects only the reporting machine — `nil` is treated as absent.
    func testMixedNilAndPresentCategorySumsOnlyPresentValues() {
        let byMachine: [String: [UsageRecord]] = [
            "withOutput": [claude(day: "2026-05-29", input: 100, output: 40, cost: 0.10)],
            "noOutput": [claude(day: "2026-05-29", input: 100, output: nil, cost: nil)]
        ]

        let result = Reconciler().merge(byMachine)

        XCTAssertEqual(result.combined.count, 1)
        let merged = result.combined[0]
        XCTAssertEqual(merged.inputTokens, 200)
        XCTAssertEqual(merged.outputTokens, 40, "Only the reporting machine contributes; nil is absent, not 0")
        XCTAssertEqual(merged.costUSD ?? 0, 0.10, accuracy: 1e-9)
    }

    // MARK: - Single machine passes through unchanged

    func testSingleMachinePassesThroughUnchanged() {
        let records = [
            claude(day: "2026-05-29", input: 100, output: 50, cacheRead: 10, cacheCreation: 5, cost: 0.20),
            codex(day: "2026-05-29", input: 300, cost: 0.30),
            claude(day: "2026-05-28", input: 80, output: 20)
        ]
        let byMachine = ["solo": records]

        let result = Reconciler().merge(byMachine)

        // Each input record is its own (day, provider, model) → one combined record
        // each, byte-for-byte identical (order aside). Compare order-independently
        // by `id` since `UsageRecord` is `Equatable` but not `Hashable`.
        XCTAssertEqual(result.combined.count, records.count)
        let combinedByID = Dictionary(uniqueKeysWithValues: result.combined.map { ($0.id, $0) })
        for record in records {
            XCTAssertEqual(combinedByID[record.id], record)
        }
        XCTAssertEqual(result.byMachine, byMachine, "byMachine is preserved verbatim for drilldown")
    }

    // MARK: - Empty input

    func testEmptyInputYieldsEmptyResult() {
        let result = Reconciler().merge([:])
        XCTAssertTrue(result.combined.isEmpty)
        XCTAssertTrue(result.byMachine.isEmpty)
    }

    func testMachinesWithEmptyRecordListsYieldNoCombinedRecords() {
        let byMachine: [String: [UsageRecord]] = ["a": [], "b": []]
        let result = Reconciler().merge(byMachine)
        XCTAssertTrue(result.combined.isEmpty)
        XCTAssertEqual(result.byMachine, byMachine, "Empty machines are still preserved in byMachine")
    }

    // MARK: - Deterministic ordering

    func testCombinedIsSortedByDayDescThenProviderThenModel() {
        let byMachine: [String: [UsageRecord]] = [
            "a": [
                codex(day: "2026-05-28", input: 1),
                claude(model: "claude-sonnet-4-7", day: "2026-05-29", input: 1),
                claude(model: "claude-opus-4-7", day: "2026-05-29", input: 1),
                codex(day: "2026-05-29", input: 1)
            ]
        ]

        let result = Reconciler().merge(byMachine)

        let order = result.combined.map { "\($0.day)|\($0.provider.rawValue)|\($0.model)" }
        XCTAssertEqual(
            order,
            [
                "2026-05-29|claude|claude-opus-4-7",
                "2026-05-29|claude|claude-sonnet-4-7",
                "2026-05-29|codex|gpt-5",
                "2026-05-28|codex|gpt-5"
            ]
        )
    }

    /// Ordering must be stable regardless of machine-key iteration order, since
    /// dictionaries are unordered. Same data, different machine names → same combined.
    func testMergeIsDeterministicAcrossMachineKeyOrder() {
        let recordsA = [claude(day: "2026-05-29", input: 100, output: 40, cost: 0.10)]
        let recordsB = [claude(day: "2026-05-29", input: 200, output: 60, cost: 0.25)]

        let first = Reconciler().merge(["zzz": recordsA, "aaa": recordsB])
        let second = Reconciler().merge(["aaa": recordsB, "zzz": recordsA])

        XCTAssertEqual(first.combined, second.combined)
    }
}
