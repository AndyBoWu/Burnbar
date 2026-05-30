import Foundation

/// The provider a usage record came from. Burnbar tracks exactly two — see the
/// two-provider hard cap in CLAUDE.md. Do not add cases without revisiting that
/// constraint (new providers tend to require browser secrets or don't persist
/// token counts, which breaks the privacy thesis).
public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    /// Human-facing label for the menu bar / popover.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "OpenAI Codex"
        }
    }
}

/// One provider+model's token usage for a single local calendar day.
///
/// This is the unified currency of Burnbar: every parser emits `UsageRecord`
/// (Epic 1.2 Claude, Epic 1.3 Codex) and every consumer — the cost engine
/// (Epic 1.4), the UI (Epic 1.5), and cross-device aggregation (M2) — reads it.
///
/// Provider asymmetry is intentional and must be preserved (see
/// docs/data-sources.md): Claude exposes the full input/output/cache breakdown,
/// while Codex stores only a single `tokens_used` integer per thread. For Codex
/// records, `tokens_used` maps to `inputTokens` and the remaining token fields
/// stay `nil`. The UI renders that difference (Codex tile = total only; Claude
/// tile = stacked breakdown), so never fabricate zeros to paper over it.
public struct UsageRecord: Codable, Sendable, Equatable, Identifiable {
    /// Provider that produced the usage.
    public let provider: Provider

    /// Raw model identifier as reported by the provider, e.g. `claude-opus-4-7`
    /// or `gpt-5`. Kept verbatim; pricing for variants is resolved later by
    /// `CostCalculator` against `PricingTable` (Epic 1.4).
    public let model: String

    /// Local calendar day this usage falls on, formatted `YYYY-MM-DD`. Every
    /// source already buckets by day (Claude `stats-cache.json` dates, Codex
    /// `DATE(created_at_ms/1000,'unixepoch')`), so this is the canonical join
    /// key across providers and, in M2, across machines.
    public let day: String

    /// Input (prompt) tokens. Always present. For Codex this carries the single
    /// `tokens_used` total, since the source exposes no finer breakdown.
    public let inputTokens: Int

    /// Output (completion) tokens. `nil` when the provider does not report it
    /// (Codex).
    public let outputTokens: Int?

    /// Cache-read input tokens. `nil` when unavailable (Codex).
    public let cacheReadTokens: Int?

    /// Cache-creation input tokens. `nil` when unavailable (Codex).
    public let cacheCreationTokens: Int?

    /// USD cost, applied post-parse by `CostCalculator` (Epic 1.4). `nil` until
    /// costing runs, or when the model is unknown to the pricing table (in which
    /// case the UI surfaces "Unknown model" rather than silently dropping it).
    public var costUSD: Double?

    public init(
        provider: Provider,
        model: String,
        day: String,
        inputTokens: Int,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.provider = provider
        self.model = model
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }

    /// Stable identity for SwiftUI lists: one record per (provider, model, day).
    public var id: String { "\(provider.rawValue)|\(model)|\(day)" }

    /// Sum of all reported token fields. Treats `nil` as absent (not zero), so a
    /// Codex record's total equals its `inputTokens`.
    public var totalTokens: Int {
        inputTokens
            + (outputTokens ?? 0)
            + (cacheReadTokens ?? 0)
            + (cacheCreationTokens ?? 0)
    }
}
