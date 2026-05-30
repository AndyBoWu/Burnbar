import Foundation

// =============================================================================
// PricingTable — authoritative per-model USD rates for Burnbar's cost engine.
//
// Sources (official pricing pages):
//   - Anthropic (Claude):  https://www.anthropic.com/pricing
//                          https://docs.anthropic.com/en/docs/about-claude/pricing
//   - OpenAI   (Codex/GPT): https://openai.com/api/pricing/
//                          https://platform.openai.com/docs/pricing
//
// Pricing snapshot: 2026-05-29
//   ^ Consumed by the 1.4.4 freshness test (`testPricingTableIsFresh`), which
//     fails if this date is more than 90 days stale. When you edit any rate
//     below, bump this date AND `snapshotDate` to the day you verified the
//     numbers against the pages above (CLAUDE.md "Pricing freshness").
//
// All rates are USD per 1,000,000 tokens (per-MTok), the unit both vendors
// publish. `CostCalculator` (1.4.2) converts to per-token at use.
//
// Two-provider hard cap (CLAUDE.md): only Claude and Codex/OpenAI models appear
// here. Do not add rates for any other vendor.
// =============================================================================

/// Per-model USD rates, expressed as dollars per 1,000,000 tokens, broken out by
/// token category.
///
/// All four fields use the same unit (USD per MTok) so `CostCalculator` can apply
/// them uniformly to a `UsageRecord`'s token breakdown. For providers that report
/// only a single total (Codex → `tokens_used` → `inputTokens`), only
/// ``inputPerMTok`` is meaningful; the cache/output fields are set to `0` because
/// the corresponding `UsageRecord` token fields are `nil` and never costed.
public struct ModelPricing: Sendable, Equatable, Hashable {
    /// USD per 1,000,000 input (prompt) tokens.
    public let inputPerMTok: Decimal

    /// USD per 1,000,000 output (completion) tokens.
    public let outputPerMTok: Decimal

    /// USD per 1,000,000 cache-read input tokens.
    public let cacheReadPerMTok: Decimal

    /// USD per 1,000,000 cache-creation (cache-write) input tokens.
    public let cacheCreatePerMTok: Decimal

    public init(
        inputPerMTok: Decimal,
        outputPerMTok: Decimal,
        cacheReadPerMTok: Decimal,
        cacheCreatePerMTok: Decimal
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheCreatePerMTok = cacheCreatePerMTok
    }
}

/// Static lookup of per-model pricing. The single source of truth for dollar
/// figures in Burnbar; `CostCalculator` (1.4.2) reads it, never hard-codes rates.
///
/// Keyed by the exact raw model id string emitted by the parsers (the same value
/// stored in `UsageRecord.model`), so lookups are a plain dictionary hit with no
/// normalization. Unknown models return `nil` from ``pricing(for:)`` so the cost
/// engine can flag them ("Unknown model") instead of silently costing them at $0.
public enum PricingTable {
    /// Date the rates below were last verified against the official pricing pages.
    /// Mirrors the `Pricing snapshot:` comment at the top of this file. The 1.4.4
    /// freshness test reads this and fails if it is more than 90 days old.
    public static let snapshotDate = "2026-05-29"

    /// All known per-model rates, keyed by exact model id.
    ///
    /// Claude entries carry the full input/output/cache breakdown (Anthropic
    /// publishes all four). Codex/OpenAI entries price only input meaningfully —
    /// Codex persists a single `tokens_used` integer that Burnbar maps to
    /// `inputTokens`, so output/cache rates are `0` and never applied.
    public static let rates: [String: ModelPricing] = [
        // --- Claude (Anthropic) — all five models observed on the real machine,
        //     per docs/data-sources.md "Models observed on real machine". ---

        // Opus tier: $15 / $75 in/out per MTok; cache read 0.1x input,
        // cache write (5m) 1.25x input.
        "claude-opus-4-7": ModelPricing(
            inputPerMTok: 15,
            outputPerMTok: 75,
            cacheReadPerMTok: 1.5,
            cacheCreatePerMTok: 18.75
        ),
        "claude-opus-4-6": ModelPricing(
            inputPerMTok: 15,
            outputPerMTok: 75,
            cacheReadPerMTok: 1.5,
            cacheCreatePerMTok: 18.75
        ),
        "claude-opus-4-5-20251101": ModelPricing(
            inputPerMTok: 15,
            outputPerMTok: 75,
            cacheReadPerMTok: 1.5,
            cacheCreatePerMTok: 18.75
        ),

        // Sonnet tier: $3 / $15 in/out per MTok; cache read 0.1x input,
        // cache write (5m) 1.25x input.
        "claude-sonnet-4-6": ModelPricing(
            inputPerMTok: 3,
            outputPerMTok: 15,
            cacheReadPerMTok: 0.3,
            cacheCreatePerMTok: 3.75
        ),

        // Haiku tier: $1 / $5 in/out per MTok; cache read 0.1x input,
        // cache write (5m) 1.25x input.
        "claude-haiku-4-5-20251001": ModelPricing(
            inputPerMTok: 1,
            outputPerMTok: 5,
            cacheReadPerMTok: 0.1,
            cacheCreatePerMTok: 1.25
        ),

        // --- OpenAI (Codex) ---
        // Codex stores only a single `tokens_used` integer per thread, which
        // Burnbar maps to `inputTokens`; output/cache fields stay `nil` and are
        // never costed, so only `inputPerMTok` is meaningful here.

        // GPT-5: $1.25 input per MTok ($10 output, listed for completeness even
        // though Codex never reports output tokens).
        "gpt-5": ModelPricing(
            inputPerMTok: 1.25,
            outputPerMTok: 10,
            cacheReadPerMTok: 0.125,
            cacheCreatePerMTok: 0
        ),

        // GPT-5.5: $1.75 input per MTok ($14 output).
        "gpt-5.5": ModelPricing(
            inputPerMTok: 1.75,
            outputPerMTok: 14,
            cacheReadPerMTok: 0.175,
            cacheCreatePerMTok: 0
        ),
    ]

    /// Returns the pricing for an exact model id, or `nil` if the model is not in
    /// the table. A `nil` result is intentional: the cost engine (1.4.2) surfaces
    /// it as "Unknown model" and treats the cost as $0 rather than guessing a
    /// rate.
    public static func pricing(for model: String) -> ModelPricing? {
        rates[model]
    }
}
