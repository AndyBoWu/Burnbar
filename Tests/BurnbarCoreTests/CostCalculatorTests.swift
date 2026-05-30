import XCTest
@testable import BurnbarCore

final class CostCalculatorTests: XCTestCase {
    private let calc = CostCalculator()

    private func record(
        _ provider: Provider,
        _ model: String,
        input: Int,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheCreation: Int? = nil,
        day: String = "2026-05-29"
    ) -> UsageRecord {
        UsageRecord(
            provider: provider,
            model: model,
            day: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation
        )
    }

    // MARK: - Reference parity (claude-usage-tracker)

    // The Python reference computes, per record:
    //   cost = Σ (tokensₖ / 1_000_000) × rate_per_mtokₖ
    // over input/output/cache_read/cache_create. These cases reproduce that
    // formula by hand from the documented PricingTable rates.

    func testOpusFullBreakdownMatchesReferenceFormula() {
        // claude-opus-4-7: input 15, output 75, cacheRead 1.5, cacheCreate 18.75 per MTok.
        let r = record(
            .claude, "claude-opus-4-7",
            input: 1_000_000,
            output: 500_000,
            cacheRead: 2_000_000,
            cacheCreation: 100_000
        )
        // 1.0*15 + 0.5*75 + 2.0*1.5 + 0.1*18.75 = 15 + 37.5 + 3 + 1.875 = 57.375
        XCTAssertEqual(calc.cost(for: r), Decimal(string: "57.375"))
    }

    func testSonnetMatchesReferenceFormula() {
        // claude-sonnet-4-6: input 3, output 15, cacheRead 0.3, cacheCreate 3.75.
        let r = record(
            .claude, "claude-sonnet-4-6",
            input: 250_000,
            output: 80_000,
            cacheRead: 1_500_000,
            cacheCreation: 40_000
        )
        // 0.25*3 + 0.08*15 + 1.5*0.3 + 0.04*3.75
        // = 0.75 + 1.2 + 0.45 + 0.15 = 2.55
        XCTAssertEqual(calc.cost(for: r), Decimal(string: "2.55"))
    }

    func testHaikuSmallCountsMatchReferenceFormula() {
        // claude-haiku-4-5-20251001: input 1, output 5, cacheRead 0.1, cacheCreate 1.25.
        let r = record(
            .claude, "claude-haiku-4-5-20251001",
            input: 12_345,
            output: 6_789,
            cacheRead: 1_111,
            cacheCreation: 222
        )
        // (12345*1 + 6789*5 + 1111*0.1 + 222*1.25) / 1_000_000
        // = (12345 + 33945 + 111.1 + 277.5) / 1e6 = 46678.6 / 1e6 = 0.0466786
        XCTAssertEqual(calc.cost(for: r), Decimal(string: "0.0466786"))
    }

    func testDailyTotalAcrossMixedModelsMatchesReference() {
        // DoD: daily cost matches the reference on identical input. Sum several
        // records on one day and compare to the hand-computed total.
        let records = [
            record(.claude, "claude-opus-4-7", input: 1_000_000, output: 500_000, cacheRead: 2_000_000, cacheCreation: 100_000), // 57.375
            record(.claude, "claude-sonnet-4-6", input: 250_000, output: 80_000, cacheRead: 1_500_000, cacheCreation: 40_000),    // 2.55
            record(.codex, "gpt-5", input: 4_000_000),                                                                            // 4.0 * 1.25 = 5.0
        ]
        // 57.375 + 2.55 + 5.0 = 64.925
        XCTAssertEqual(calc.cost(for: records), Decimal(string: "64.925"))
    }

    // MARK: - Codex nil-field handling

    func testCodexRecordPricesInputOnlyWithoutCrashing() {
        // Codex: only inputTokens populated (tokens_used); rest nil → priced as 0.
        // gpt-5 input rate 1.25/MTok. 2_000_000 tokens → 2.0 * 1.25 = 2.5.
        let r = record(.codex, "gpt-5", input: 2_000_000)
        let result = calc.result(for: r)
        XCTAssertFalse(result.isUnknownModel)
        XCTAssertEqual(result.cost, Decimal(string: "2.5"))
    }

    func testNilTokenFieldsCountAsZeroNotMissing() {
        // A Claude record missing cache/output fields must price input only,
        // identical to filling those fields with explicit zeros.
        let sparse = record(.claude, "claude-opus-4-7", input: 1_000_000)
        let explicitZeros = record(
            .claude, "claude-opus-4-7",
            input: 1_000_000, output: 0, cacheRead: 0, cacheCreation: 0
        )
        XCTAssertEqual(calc.cost(for: sparse), calc.cost(for: explicitZeros))
        XCTAssertEqual(calc.cost(for: sparse), Decimal(string: "15")) // 1.0 * 15
    }

    // MARK: - Unknown model

    func testUnknownModelCostsZeroAndFlags() {
        let r = record(.claude, "gemini-2.0", input: 9_999_999, output: 5_000_000)
        let result = calc.result(for: r)
        XCTAssertTrue(result.isUnknownModel, "unknown model must be flagged for the UI")
        XCTAssertEqual(result.cost, 0, "unknown model is costed at $0, never guessed")
    }

    func testUnknownModelRecordIsPricedNotDropped() {
        // `priced(_:)` must return the record (with costUSD = 0), never drop it.
        let records = [
            record(.claude, "claude-opus-4-7", input: 1_000_000), // 15
            record(.claude, "mystery-model", input: 5_000_000),   // unknown → 0
        ]
        let priced = calc.priced(records)
        XCTAssertEqual(priced.count, 2, "unknown-model record must be retained")
        XCTAssertEqual(priced[0].costUSD ?? -1, 15.0, accuracy: 1e-9)
        XCTAssertEqual(priced[1].costUSD ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(priced[1].model, "mystery-model")
    }

    func testEmptyModelStringIsUnknown() {
        let r = record(.claude, "", input: 1_000_000)
        XCTAssertTrue(calc.result(for: r).isUnknownModel)
    }

    // MARK: - priced(_:) helper

    func testPricedPopulatesCostUSDPreservingOtherFields() {
        let r = record(.claude, "claude-sonnet-4-6", input: 250_000, output: 80_000, cacheRead: 1_500_000, cacheCreation: 40_000)
        let priced = calc.priced(r)
        XCTAssertEqual(priced.costUSD ?? -1, 2.55, accuracy: 1e-9)
        // Untouched fields survive.
        XCTAssertEqual(priced.provider, r.provider)
        XCTAssertEqual(priced.model, r.model)
        XCTAssertEqual(priced.day, r.day)
        XCTAssertEqual(priced.inputTokens, r.inputTokens)
        XCTAssertEqual(priced.outputTokens, r.outputTokens)
        XCTAssertEqual(priced.cacheReadTokens, r.cacheReadTokens)
        XCTAssertEqual(priced.cacheCreationTokens, r.cacheCreationTokens)
    }

    func testPricedRecordsFeedAggregatorCleanly() {
        // Sanity: priced records flow into the aggregator and their costUSD sums.
        let records = calc.priced([
            record(.claude, "claude-opus-4-7", input: 1_000_000),  // 15
            record(.codex, "gpt-5", input: 4_000_000),             // 5
        ])
        let agg = TimeWindowAggregator()
        let today = agg.aggregate(records, window: .today, now: makeNoon("2026-05-29"))
        XCTAssertEqual(today.costUSD, 20.0, accuracy: 1e-9)
    }

    // MARK: - Zero / empty

    func testZeroTokensCostZeroForKnownModel() {
        let r = record(.claude, "claude-opus-4-7", input: 0)
        let result = calc.result(for: r)
        XCTAssertFalse(result.isUnknownModel)
        XCTAssertEqual(result.cost, 0)
    }

    func testEmptyBatchCostsZero() {
        XCTAssertEqual(calc.cost(for: [UsageRecord]()), 0)
        XCTAssertTrue(calc.priced([UsageRecord]()).isEmpty)
    }

    // MARK: - Injected lookup

    func testInjectedPricingLookupIsUsed() {
        // A custom lookup proves rates aren't hard-coded into the calculator.
        let custom = CostCalculator { model in
            model == "test-model"
                ? ModelPricing(inputPerMTok: 100, outputPerMTok: 0, cacheReadPerMTok: 0, cacheCreatePerMTok: 0)
                : nil
        }
        let r = record(.claude, "test-model", input: 1_000_000)
        XCTAssertEqual(custom.cost(for: r), Decimal(string: "100"))
        // Real Claude model is unknown to this injected table → flagged.
        XCTAssertTrue(custom.result(for: record(.claude, "claude-opus-4-7", input: 1)).isUnknownModel)
    }

    // MARK: - Helpers

    private func makeNoon(_ day: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let midnight = f.date(from: day)!
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: midnight)!
    }
}
