import BurnbarCore
import SwiftUI

/// Placeholder default token budgets per burn window.
///
/// These are **not** real plan limits — they are sensible round-number
/// placeholders so the bars have something to fill against until per-user limits
/// are user-configurable in Settings (sub-ticket 1.5.6). Do not present these as
/// authoritative quotas; they exist only to demonstrate fill/percentage/animation.
enum BurnBudget {
    /// Placeholder weekly token budget. User-configurable later (1.5.6).
    static let weeklyTokens = 10_000_000
    /// Placeholder monthly token budget. User-configurable later (1.5.6).
    static let monthlyTokens = 40_000_000
    /// Placeholder rolling 5-hour token budget. Not currently wired (see
    /// `PopoverContentView`) because `UsageRecord` is day-granular.
    static let fiveHourTokens = 2_000_000

    /// The default placeholder budget for a window.
    static func tokens(for window: BurnWindow) -> Int {
        switch window {
        case .fiveHour: return fiveHourTokens
        case .weekly: return weeklyTokens
        case .monthly: return monthlyTokens
        }
    }
}

/// A horizontal progress "burn bar": shows how far the current `value` has
/// consumed `limit` for a given `BurnWindow`, with a percentage label and a live
/// countdown to the next reset.
///
/// - Fill is clamped to `0...1`, so over-limit usage reads as a full bar (and the
///   percentage label can still report >100%).
/// - The countdown is driven by `TimelineView(.periodic)` so it updates roughly
///   once a minute without an external timer, recomputing against
///   `ResetClock.nextReset(for:)`.
/// - Fill changes animate via `withAnimation` keyed on `value`, satisfying the
///   "bars animate" Definition of Done for 1.5.3.
@MainActor
struct BurnBarView: View {
    /// Current consumed amount (tokens) in this window.
    let value: Int
    /// The budget/limit this window fills against (tokens). See `BurnBudget`.
    let limit: Int
    /// Which reset cadence this bar tracks.
    let window: BurnWindow

    /// Clock used to compute the next reset. Injectable for previews/tests.
    var clock = ResetClock()

    /// Fraction filled, clamped to a drawable `0...1`.
    private var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(limit)))
    }

    /// Raw percentage (may exceed 100 when over budget) for the label.
    private var percent: Int {
        guard limit > 0 else { return 0 }
        return Int((Double(value) / Double(limit) * 100).rounded())
    }

    /// Bar tint: green under 75%, orange to 100%, red when over budget.
    private var tint: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<1.0: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(percent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            bar

            HStack {
                Text("\(BurnFormat.tokens(value)) / \(BurnFormat.tokens(limit)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                countdown
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.displayName) usage")
        .accessibilityValue("\(percent) percent of limit used")
    }

    /// The track + animated fill. `GeometryReader` gives the fill an explicit
    /// width so the animation interpolates the bar length, not just opacity.
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(.easeInOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: 6)
    }

    /// Live countdown to the next reset. `TimelineView(.periodic)` re-renders the
    /// label about once a minute; each render recomputes the remaining time from
    /// the timeline's own date, so it stays correct without a stored timer.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("resets in " + Self.format(clock.timeRemaining(for: window, now: context.date)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// Format a duration as a compact human string: `2h 14m`, `45m`, or `<1m`.
    /// Days roll up into hours where relevant (e.g. weekly/monthly windows show
    /// `3d 4h`).
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        guard total > 0 else { return "<1m" }

        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }
}

#if DEBUG
#Preview("Burn bars") {
    VStack(spacing: 12) {
        BurnBarView(value: 3_200_000, limit: BurnBudget.weeklyTokens, window: .weekly)
        BurnBarView(value: 38_000_000, limit: BurnBudget.monthlyTokens, window: .monthly)
        BurnBarView(value: 2_500_000, limit: BurnBudget.fiveHourTokens, window: .fiveHour)
    }
    .padding()
    .frame(width: 300)
}
#endif
