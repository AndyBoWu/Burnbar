import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``LeaderboardAggregator`` to assert the M3 Definition of Done: output
/// rows sum to the source totals, every record collapses into exactly one row per
/// `(date, provider)` with models folded away, and the serialized payload carries
/// **only** `date` / `provider` / `tokens` / `cost_usd` — no `model`, no
/// `machine_id`, no paths.
final class LeaderboardAggregatorTests: XCTestCase {

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
    /// (docs/data-sources.md). Proves the aggregator never fabricates zeros and
    /// that `totalTokens` == `inputTokens` for Codex.
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

    // MARK: - Per-(date, provider) summation

    func testSumsTokensAndCostPerDateProvider() {
        let records = [
            claude(day: "2026-05-29", input: 100, output: 50, cacheRead: 10, cacheCreation: 5, cost: 0.20),
            claude(day: "2026-05-29", input: 200, output: 80, cacheRead: 20, cacheCreation: 7, cost: 0.40)
        ]

        let rows = LeaderboardAggregator().aggregate(records)

        XCTAssertEqual(rows.count, 1, "Same (date, provider) collapses to one row")
        let row = rows[0]
        XCTAssertEqual(row.date, "2026-05-29")
        XCTAssertEqual(row.provider, .claude)
        // 100+50+10+5 = 165, 200+80+20+7 = 307 → 472.
        XCTAssertEqual(row.tokens, 472)
        XCTAssertEqual(row.costUSD, 0.60, accuracy: 1e-9)
    }

    /// `tokens` must equal the sum of every input record's `totalTokens`, and
    /// `cost_usd` the sum of every `costUSD` — the core DoD invariant.
    func testOutputTotalsEqualSumOfInput() {
        let records = [
            claude(day: "2026-05-29", input: 100, output: 50, cacheRead: 10, cacheCreation: 5, cost: 0.20),
            claude(model: "claude-sonnet-4-7", day: "2026-05-29", input: 30, output: 12, cost: 0.05),
            codex(day: "2026-05-29", input: 300, cost: 0.30),
            claude(day: "2026-05-28", input: 90, output: 30, cost: 0.10),
            codex(day: "2026-05-28", input: 40)
        ]

        let rows = LeaderboardAggregator().aggregate(records)

        let outputTokens = rows.reduce(0) { $0 + $1.tokens }
        let inputTokens = records.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(outputTokens, inputTokens)

        let outputCost = rows.reduce(0) { $0 + $1.costUSD }
        let inputCost = records.reduce(0) { $0 + ($1.costUSD ?? 0) }
        XCTAssertEqual(outputCost, inputCost, accuracy: 1e-9)
    }

    // MARK: - Multiple days / providers

    func testMultipleDaysAndProvidersProduceOneRowEach() {
        let records = [
            claude(day: "2026-05-29", input: 100, cost: 0.10),
            codex(day: "2026-05-29", input: 300, cost: 0.30),
            claude(day: "2026-05-28", input: 50, cost: 0.05),
            codex(day: "2026-05-28", input: 200, cost: 0.20)
        ]

        let rows = LeaderboardAggregator().aggregate(records)

        XCTAssertEqual(rows.count, 4, "Two days x two providers → four distinct rows")
        // Deterministic order: day descending, then provider (claude < codex).
        XCTAssertEqual(
            rows.map(\.id),
            ["2026-05-29|claude", "2026-05-29|codex", "2026-05-28|claude", "2026-05-28|codex"]
        )

        let codex29 = rows.first { $0.id == "2026-05-29|codex" }
        XCTAssertEqual(codex29?.tokens, 300)
        XCTAssertEqual(codex29?.costUSD ?? 0, 0.30, accuracy: 1e-9)
    }

    // MARK: - Model names collapse away

    func testDifferentModelsSameProviderCollapseIntoOneRow() {
        let records = [
            claude(model: "claude-opus-4-7", day: "2026-05-29", input: 100, output: 40, cost: 0.20),
            claude(model: "claude-sonnet-4-7", day: "2026-05-29", input: 60, output: 20, cost: 0.05),
            claude(model: "claude-haiku-4-7", day: "2026-05-29", input: 10, output: 5, cost: 0.01)
        ]

        let rows = LeaderboardAggregator().aggregate(records)

        XCTAssertEqual(rows.count, 1, "Three Claude models on one day → one (date, provider) row")
        let row = rows[0]
        XCTAssertEqual(row.tokens, 140 + 80 + 15)
        XCTAssertEqual(row.costUSD, 0.26, accuracy: 1e-9)
    }

    // MARK: - Cross-machine via ReconciledUsage

    /// The aggregator consumes the M2 reconciler's combined (cross-machine) view
    /// and never the per-machine breakdown.
    func testAggregatesReconciledCombinedViewAcrossMachines() {
        let byMachine: [String: [UsageRecord]] = [
            "mac-air": [
                claude(day: "2026-05-29", input: 100, output: 50, cacheRead: 10, cacheCreation: 5, cost: 0.20),
                codex(day: "2026-05-29", input: 300, cost: 0.30)
            ],
            "mac-studio": [
                claude(day: "2026-05-29", input: 200, output: 80, cacheRead: 20, cacheCreation: 7, cost: 0.40)
            ]
        ]
        let reconciled = Reconciler().merge(byMachine)

        let rows = LeaderboardAggregator().aggregate(reconciled)

        XCTAssertEqual(rows.count, 2, "claude + codex on one day → two rows")

        // Output must equal the flat sum of every per-machine record.
        let flat = byMachine.values.flatMap(\.self)
        let expectedTokens = flat.reduce(0) { $0 + $1.totalTokens }
        let expectedCost = flat.reduce(0) { $0 + ($1.costUSD ?? 0) }
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, expectedTokens)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.costUSD }, expectedCost, accuracy: 1e-9)

        let claudeRow = rows.first { $0.provider == .claude }
        XCTAssertEqual(claudeRow?.tokens, 165 + 307)
        XCTAssertEqual(claudeRow?.costUSD ?? 0, 0.60, accuracy: 1e-9)
    }

    // MARK: - nil cost contributes zero, never fabricates a value

    func testNilCostContributesZero() {
        // Same provider so the two records collapse into one row, exercising the
        // mix of a nil-cost record (counts as 0) and a costed one in one bucket.
        let records = [
            codex(model: "gpt-5", day: "2026-05-29", input: 300, cost: nil),
            codex(model: "gpt-5-mini", day: "2026-05-29", input: 100, cost: 0.10)
        ]

        let rows = LeaderboardAggregator().aggregate(records)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tokens, 300 + 100)
        XCTAssertEqual(rows[0].costUSD, 0.10, accuracy: 1e-9, "nil cost counts as 0, not dropped")
    }

    // MARK: - Privacy: payload carries ONLY date/provider/tokens/cost_usd

    func testEncodedPayloadCarriesOnlyAllowedKeys() throws {
        let records = [
            claude(model: "claude-opus-4-7", day: "2026-05-29", input: 100, output: 40, cacheRead: 10, cost: 0.20),
            codex(model: "gpt-5", day: "2026-05-29", input: 300, cost: 0.30)
        ]
        let rows = LeaderboardAggregator().aggregate(records)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rows)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        // The wire payload must use exactly the validator-mandated keys.
        let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let row = try XCTUnwrap(objects?.first)
        XCTAssertEqual(Set(row.keys), ["date", "provider", "tokens", "cost_usd"])

        // And must contain none of the forbidden / identifying fields or values —
        // no model name, no machine id, no path, no internal camelCase cost key.
        for forbidden in [
            "model", "machine_id", "machineID", "cwd", "git", "path",
            "costUSD", "inputTokens", "outputTokens", "cacheReadTokens",
            "claude-opus-4-7", "gpt-5"
        ] {
            XCTAssertFalse(json.contains(forbidden), "Leaderboard payload must not contain '\(forbidden)'")
        }
    }

    // MARK: - Empty input

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(LeaderboardAggregator().aggregate([UsageRecord]()).isEmpty)
        let emptyReconciled = Reconciler().merge([:])
        XCTAssertTrue(LeaderboardAggregator().aggregate(emptyReconciled).isEmpty)
    }
}
