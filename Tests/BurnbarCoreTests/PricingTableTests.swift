import XCTest
@testable import BurnbarCore

final class PricingTableTests: XCTestCase {
    /// The five Claude model ids from docs/data-sources.md "Models observed on
    /// real machine" — the Definition of Done requires every one to be priced.
    private let requiredClaudeModels = [
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001",
    ]

    func testCoversAllRealMachineClaudeModels() {
        for model in requiredClaudeModels {
            XCTAssertNotNil(
                PricingTable.pricing(for: model),
                "Missing pricing for required Claude model \(model) (see data-sources.md)"
            )
        }
    }

    func testCoversCodexModels() {
        XCTAssertNotNil(PricingTable.pricing(for: "gpt-5"), "DoD requires GPT-5 pricing")
        XCTAssertNotNil(PricingTable.pricing(for: "gpt-5.5"), "DoD requires GPT-5.5 pricing")
    }

    func testUnknownModelReturnsNil() {
        // 1.4.2 relies on nil to flag "Unknown model" rather than costing at $0.
        XCTAssertNil(PricingTable.pricing(for: "gemini-2.0"))
        XCTAssertNil(PricingTable.pricing(for: ""))
        XCTAssertNil(PricingTable.pricing(for: "claude-opus-4-7-20999999"))
    }

    func testRatesAreNonNegative() {
        for (model, pricing) in PricingTable.rates {
            XCTAssertGreaterThanOrEqual(pricing.inputPerMTok, 0, "\(model) input rate < 0")
            XCTAssertGreaterThanOrEqual(pricing.outputPerMTok, 0, "\(model) output rate < 0")
            XCTAssertGreaterThanOrEqual(pricing.cacheReadPerMTok, 0, "\(model) cacheRead rate < 0")
            XCTAssertGreaterThanOrEqual(pricing.cacheCreatePerMTok, 0, "\(model) cacheCreate rate < 0")
        }
    }

    func testClaudeInputRateIsMeaningfullyPositive() {
        // Every priced Claude model must charge for input — a $0 input rate would
        // silently zero out real cost.
        for model in requiredClaudeModels {
            let pricing = PricingTable.pricing(for: model)
            XCTAssertGreaterThan(
                pricing?.inputPerMTok ?? 0,
                0,
                "\(model) must have a positive input rate"
            )
        }
    }

    func testCodexInputRateIsMeaningful() {
        // Codex prices only input meaningfully (tokens_used -> inputTokens).
        XCTAssertGreaterThan(PricingTable.pricing(for: "gpt-5")?.inputPerMTok ?? 0, 0)
        XCTAssertGreaterThan(PricingTable.pricing(for: "gpt-5.5")?.inputPerMTok ?? 0, 0)
    }

    func testOpusKnownRates() {
        // Spot-check the Opus tier against the documented snapshot.
        let opus = PricingTable.pricing(for: "claude-opus-4-7")
        XCTAssertEqual(opus?.inputPerMTok, 15)
        XCTAssertEqual(opus?.outputPerMTok, 75)
        XCTAssertEqual(opus?.cacheReadPerMTok, 1.5)
        XCTAssertEqual(opus?.cacheCreatePerMTok, 18.75)
    }

    func testSonnetAndHaikuKnownRates() {
        let sonnet = PricingTable.pricing(for: "claude-sonnet-4-6")
        XCTAssertEqual(sonnet?.inputPerMTok, 3)
        XCTAssertEqual(sonnet?.outputPerMTok, 15)

        let haiku = PricingTable.pricing(for: "claude-haiku-4-5-20251001")
        XCTAssertEqual(haiku?.inputPerMTok, 1)
        XCTAssertEqual(haiku?.outputPerMTok, 5)
    }

    func testCacheReadIsCheaperThanInput() {
        // Sanity: cache reads are always discounted vs. fresh input.
        for (model, pricing) in PricingTable.rates where pricing.cacheReadPerMTok > 0 {
            XCTAssertLessThan(
                pricing.cacheReadPerMTok,
                pricing.inputPerMTok,
                "\(model) cache-read rate should be below input rate"
            )
        }
    }

    func testSnapshotDateIsValidISODate() {
        // The 1.4.4 freshness test parses this; guard the format here.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertNotNil(
            formatter.date(from: PricingTable.snapshotDate),
            "snapshotDate must be a valid YYYY-MM-DD string"
        )
    }
}
