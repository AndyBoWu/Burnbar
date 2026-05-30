import XCTest
@testable import BurnbarCore

final class UsageRecordTests: XCTestCase {
    func testClaudeRecordKeepsFullBreakdown() {
        let record = UsageRecord(
            provider: .claude,
            model: "claude-opus-4-7",
            day: "2026-05-29",
            inputTokens: 2,
            outputTokens: 137,
            cacheReadTokens: 0,
            cacheCreationTokens: 31824
        )
        XCTAssertEqual(record.totalTokens, 2 + 137 + 0 + 31824)
        XCTAssertEqual(record.id, "claude|claude-opus-4-7|2026-05-29")
    }

    func testCodexRecordLeavesNonInputFieldsNil() {
        // Codex stores only tokens_used -> inputTokens; the rest must stay nil
        // so the UI can render the provider asymmetry honestly.
        let record = UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 4200)
        XCTAssertNil(record.outputTokens)
        XCTAssertNil(record.cacheReadTokens)
        XCTAssertNil(record.cacheCreationTokens)
        XCTAssertEqual(record.totalTokens, 4200)
    }

    func testCodableRoundTripPreservesNilsAndCost() throws {
        let record = UsageRecord(
            provider: .claude,
            model: "claude-sonnet-4-6",
            day: "2026-05-28",
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheCreationTokens: 40,
            costUSD: 1.23
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: data)
        XCTAssertEqual(record, decoded)
    }

    func testProviderCapAndDisplayNames() {
        XCTAssertEqual(Provider.allCases.count, 2, "Two-provider hard cap — see CLAUDE.md")
        XCTAssertEqual(Provider.claude.displayName, "Claude Code")
        XCTAssertEqual(Provider.codex.displayName, "OpenAI Codex")
    }
}
