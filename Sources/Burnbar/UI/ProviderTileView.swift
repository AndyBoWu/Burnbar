import BurnbarCore
import SwiftUI

/// View-model for one provider's tile, derived from a `WindowAggregate`.
struct ProviderTileModel: Identifiable {
    let provider: Provider
    let costUSD: Double
    let totalTokens: Int
    /// Stacked breakdown — only meaningful for Claude. For Codex these mirror
    /// the single `tokens_used` total (input) with the rest at 0.
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// Top models by token count (max 3).
    let topModels: [ModelRow]

    var id: Provider { provider }

    struct ModelRow: Identifiable {
        let name: String
        let tokens: Int
        /// Model not found in `PricingTable` — surfaced distinctly per 1.4.2.
        let isUnknown: Bool
        var id: String { name }
    }

    /// Build a tile model for `provider` from the aggregated window. Returns
    /// `nil` when the provider has no records in the window (fresh install).
    static func make(provider: Provider, from aggregate: WindowAggregate) -> ProviderTileModel? {
        guard let breakdown = aggregate.byProvider[provider] else { return nil }
        let topModels = aggregate.byModel
            .filter { $0.value.provider == provider }
            .map { ModelRow(
                name: $0.key,
                tokens: $0.value.totalTokens,
                isUnknown: PricingTable.pricing(for: $0.key) == nil
            ) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(3)
        return ProviderTileModel(
            provider: provider,
            costUSD: breakdown.costUSD,
            totalTokens: breakdown.totalTokens,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheReadTokens: breakdown.cacheReadTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            topModels: Array(topModels)
        )
    }
}

/// A per-provider card: today's spend, token total, the Claude/Codex breakdown
/// asymmetry, and the top-3 models. Shows a "no usage today" state when the
/// provider has no records.
struct ProviderTileView: View {
    let provider: Provider
    let model: ProviderTileModel?

    private var accent: Color { provider == .claude ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(provider.displayName, systemImage: "circle.fill")
                    .labelStyle(BadgeLabelStyle(color: accent))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let model {
                    Text(BurnFormat.cost(model.costUSD))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
            }

            if let model {
                Text("\(BurnFormat.tokens(model.totalTokens)) tokens today")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Claude exposes a full breakdown; Codex reports only a total.
                if provider == .claude {
                    Text(breakdownLine(model))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !model.topModels.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.topModels) { row in
                            HStack(spacing: 4) {
                                Text(row.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if row.isUnknown {
                                    Text("Unknown model")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.yellow.opacity(0.25), in: Capsule())
                                }
                                Spacer()
                                Text(BurnFormat.tokens(row.tokens))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                Text("No usage today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdownLine(_ model: ProviderTileModel) -> String {
        "in \(BurnFormat.tokens(model.inputTokens))  ·  out \(BurnFormat.tokens(model.outputTokens))  ·  cache \(BurnFormat.tokens(model.cacheReadTokens + model.cacheCreationTokens))"
    }
}

/// Small leading colored dot + title.
private struct BadgeLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color).font(.system(size: 7))
            configuration.title
        }
    }
}

/// Compact human formatting for tokens and cost.
enum BurnFormat {
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1000...:
            return String(format: "%.1fK", Double(count) / 1000)
        default:
            return "\(count)"
        }
    }

    static func cost(_ usd: Double) -> String {
        if usd > 0, usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }
}
