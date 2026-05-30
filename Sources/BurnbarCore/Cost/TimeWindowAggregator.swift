import Foundation

/// One of the three burn windows the popover surfaces: today, this week, this
/// month. Boundaries are always derived from `Calendar.current` (the user's
/// local calendar + timezone) so the numbers line up with the clock on the
/// user's own wall — never UTC. See `TimeWindowAggregator`.
public enum TimeWindow: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The current local calendar day (`Calendar.startOfDay(for:)` … next day).
    case today
    /// The current week-of-year, per `Calendar.current` (honours the user's
    /// `firstWeekday`, e.g. Sunday in the US, Monday in much of Europe).
    case week
    /// The current calendar month.
    case month

    public var id: String { rawValue }

    /// Human-facing label for the popover segmented control.
    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        }
    }
}

/// Summed token usage + cost for a single `TimeWindow`, with optional
/// per-provider and per-model breakdowns for the UI to drill into.
///
/// Token fields mirror `UsageRecord`'s categories. Because Codex reports only a
/// single `tokens_used` total (mapped to `inputTokens`, the rest `nil`), the
/// per-category sums here treat `nil` as 0 — but `outputTokens` / cache fields
/// for a Codex-only window will simply stay 0, preserving the provider
/// asymmetry rather than fabricating a breakdown.
public struct WindowAggregate: Sendable, Equatable {
    /// The window these totals describe.
    public let window: TimeWindow

    /// Summed input (prompt) tokens across every record in the window.
    public let inputTokens: Int
    /// Summed output (completion) tokens; `nil` fields counted as 0.
    public let outputTokens: Int
    /// Summed cache-read input tokens; `nil` fields counted as 0.
    public let cacheReadTokens: Int
    /// Summed cache-creation input tokens; `nil` fields counted as 0.
    public let cacheCreationTokens: Int

    /// Total USD cost across the window. `nil` costs (uncosted or unknown-model
    /// records) are counted as 0 — the UI surfaces "Unknown model" separately;
    /// the aggregator never silently inflates the dollar figure.
    public let costUSD: Double

    /// Per-provider rollup. Sums for Claude and/or Codex when present. Absent
    /// providers are simply omitted from the dictionary.
    public let byProvider: [Provider: ProviderBreakdown]

    /// Per-model rollup keyed by the raw model identifier (e.g. `claude-opus-4-7`,
    /// `gpt-5`). Useful for the popover's "top 3 models" list.
    public let byModel: [String: ModelBreakdown]

    /// Sum of every token category. For a Codex-only window this equals
    /// `inputTokens`, since the other categories stay 0.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Per-provider token + cost rollup.
    public struct ProviderBreakdown: Sendable, Equatable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreationTokens: Int
        public let costUSD: Double

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        }
    }

    /// Per-model token + cost rollup. `provider` is retained so the UI can label
    /// the model row with its source even when grouped purely by model name.
    public struct ModelBreakdown: Sendable, Equatable {
        public let provider: Provider
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreationTokens: Int
        public let costUSD: Double

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        }
    }
}

/// Buckets priced `UsageRecord`s into today / week / month windows using the
/// user's local calendar.
///
/// `UsageRecord.day` is a `YYYY-MM-DD` string already bucketed to a local
/// calendar day by each parser. The aggregator parses that string back into a
/// `Date` anchored at **noon local time** and tests it against window intervals
/// produced by `Calendar.current`:
///
/// - **today** — `[startOfDay(for: now), start of next day)`.
/// - **week**  — `dateInterval(of: .weekOfYear, for: now)`.
/// - **month** — `dateInterval(of: .month, for: now)`.
///
/// Anchoring at noon (rather than midnight) sidesteps DST transition days where
/// `00:00` either does not exist or occurs twice: noon is unambiguous in every
/// real-world timezone, so a day never drifts into the wrong bucket. Because the
/// intervals themselves come from `Calendar.current`, week boundaries honour the
/// user's `firstWeekday` and all comparisons stay in local time.
///
/// The aggregator is `Sendable` and holds only an immutable `Calendar`, so it is
/// safe to share across the app's concurrency domains.
public struct TimeWindowAggregator: Sendable {
    /// Calendar used to derive window boundaries. Defaults to `.current` so the
    /// user's locale/timezone/`firstWeekday` drive bucketing; injectable for
    /// deterministic tests (fixed timezone, fixed `firstWeekday`).
    public let calendar: Calendar

    /// Parses `UsageRecord.day` (`YYYY-MM-DD`). `en_US_POSIX` + a fixed format
    /// keeps parsing independent of the user's locale; the timezone is taken
    /// from `calendar` so the parsed instant lands on the intended local day.
    private let dayParser: DateFormatter

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayParser = formatter
    }

    /// Aggregate `records` into the three windows, evaluated relative to `now`
    /// (defaults to the current instant; injectable for tests).
    ///
    /// Returns a dictionary keyed by `TimeWindow` with an entry for every case,
    /// even when a window has no matching records (an empty `WindowAggregate`).
    /// A single record can land in more than one window (today ⊂ week ⊂ month is
    /// common but not guaranteed — e.g. the first of the month may fall outside
    /// the current week), so windows are summed independently.
    public func aggregate(
        _ records: [UsageRecord],
        now: Date = Date()
    ) -> [TimeWindow: WindowAggregate] {
        let intervals = windowIntervals(now: now)

        // Accumulators per window.
        var accumulators: [TimeWindow: Accumulator] = [:]
        for window in TimeWindow.allCases {
            accumulators[window] = Accumulator(window: window)
        }

        for record in records {
            guard let date = date(for: record.day) else { continue }
            for window in TimeWindow.allCases {
                guard let interval = intervals[window], interval.contains(date) else { continue }
                accumulators[window]?.add(record)
            }
        }

        var result: [TimeWindow: WindowAggregate] = [:]
        for (window, accumulator) in accumulators {
            result[window] = accumulator.finalize()
        }
        return result
    }

    /// Aggregate `records` into a single `window`. Convenience over `aggregate`.
    public func aggregate(
        _ records: [UsageRecord],
        window: TimeWindow,
        now: Date = Date()
    ) -> WindowAggregate {
        aggregate(records, now: now)[window] ?? Accumulator(window: window).finalize()
    }

    /// The local-time `DateInterval` for each window, relative to `now`.
    /// Exposed for tests and for UI that wants to show the active range.
    public func windowIntervals(now: Date) -> [TimeWindow: DateInterval] {
        var intervals: [TimeWindow: DateInterval] = [:]

        let startOfToday = calendar.startOfDay(for: now)
        if let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) {
            intervals[.today] = DateInterval(start: startOfToday, end: startOfTomorrow)
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            intervals[.week] = week
        }
        if let month = calendar.dateInterval(of: .month, for: now) {
            intervals[.month] = month
        }
        return intervals
    }

    /// Parse a `YYYY-MM-DD` day string to a local-noon `Date`, or `nil` if the
    /// string is malformed. Noon anchoring keeps the instant DST-safe.
    func date(for day: String) -> Date? {
        guard let midnight = dayParser.date(from: day) else { return nil }
        // dayParser produces local midnight; shift to local noon for DST safety.
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: midnight) ?? midnight
    }

    /// Mutable per-window accumulator, collapsed into an immutable aggregate.
    private struct Accumulator {
        let window: TimeWindow
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var cost = 0.0

        var providerInput: [Provider: Int] = [:]
        var providerOutput: [Provider: Int] = [:]
        var providerCacheRead: [Provider: Int] = [:]
        var providerCacheCreation: [Provider: Int] = [:]
        var providerCost: [Provider: Double] = [:]

        var modelProvider: [String: Provider] = [:]
        var modelInput: [String: Int] = [:]
        var modelOutput: [String: Int] = [:]
        var modelCacheRead: [String: Int] = [:]
        var modelCacheCreation: [String: Int] = [:]
        var modelCost: [String: Double] = [:]

        mutating func add(_ record: UsageRecord) {
            let inTok = record.inputTokens
            let outTok = record.outputTokens ?? 0
            let crTok = record.cacheReadTokens ?? 0
            let ccTok = record.cacheCreationTokens ?? 0
            let usd = record.costUSD ?? 0

            input += inTok
            output += outTok
            cacheRead += crTok
            cacheCreation += ccTok
            cost += usd

            let p = record.provider
            providerInput[p, default: 0] += inTok
            providerOutput[p, default: 0] += outTok
            providerCacheRead[p, default: 0] += crTok
            providerCacheCreation[p, default: 0] += ccTok
            providerCost[p, default: 0] += usd

            let m = record.model
            modelProvider[m] = p
            modelInput[m, default: 0] += inTok
            modelOutput[m, default: 0] += outTok
            modelCacheRead[m, default: 0] += crTok
            modelCacheCreation[m, default: 0] += ccTok
            modelCost[m, default: 0] += usd
        }

        func finalize() -> WindowAggregate {
            var byProvider: [Provider: WindowAggregate.ProviderBreakdown] = [:]
            // `add` always touches every provider dictionary together, so
            // `providerInput.keys` is the full set of providers seen.
            for p in providerInput.keys {
                byProvider[p] = WindowAggregate.ProviderBreakdown(
                    inputTokens: providerInput[p] ?? 0,
                    outputTokens: providerOutput[p] ?? 0,
                    cacheReadTokens: providerCacheRead[p] ?? 0,
                    cacheCreationTokens: providerCacheCreation[p] ?? 0,
                    costUSD: providerCost[p] ?? 0
                )
            }

            var byModel: [String: WindowAggregate.ModelBreakdown] = [:]
            for m in modelProvider.keys {
                byModel[m] = WindowAggregate.ModelBreakdown(
                    provider: modelProvider[m] ?? .claude,
                    inputTokens: modelInput[m] ?? 0,
                    outputTokens: modelOutput[m] ?? 0,
                    cacheReadTokens: modelCacheRead[m] ?? 0,
                    cacheCreationTokens: modelCacheCreation[m] ?? 0,
                    costUSD: modelCost[m] ?? 0
                )
            }

            return WindowAggregate(
                window: window,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                costUSD: cost,
                byProvider: byProvider,
                byModel: byModel
            )
        }
    }
}
