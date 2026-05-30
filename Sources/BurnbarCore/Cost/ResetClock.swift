import Foundation

/// The three rate-limit "burn windows" a `BurnBarView` can track, each with its
/// own reset cadence. These mirror the plan-limit buckets users care about: a
/// rolling 5-hour window, a fixed weekly window, and a fixed monthly window.
///
/// Kept distinct from `TimeWindow` (the *aggregation* buckets today/week/month):
/// `BurnWindow` is about **when a limit resets**, not which records sum into a
/// total. The two overlap for week/month but `fiveHour` has no aggregation
/// counterpart because `UsageRecord` is day-granular (see `ResetClock`).
public enum BurnWindow: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A rolling 5-hour window. Resets 5 hours after `now` — there is no fixed
    /// boundary; the window slides continuously.
    case fiveHour
    /// A fixed weekly window. Resets at the start of next week per
    /// `Calendar.current` (honours the user's `firstWeekday`).
    case weekly
    /// A fixed monthly window. Resets at the start of next calendar month.
    case monthly

    public var id: String { rawValue }

    /// Human-facing label for the burn bar row.
    public var displayName: String {
        switch self {
        case .fiveHour: return "5-Hour"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

/// Computes the next reset instant for a `BurnWindow`, using an injectable
/// `Calendar` so boundaries follow the user's local timezone + `firstWeekday`
/// (consistent with `TimeWindowAggregator` and sub-ticket 1.4.3) while staying
/// deterministic in tests.
///
/// Reset semantics:
/// - `.fiveHour` — **rolling**: `now + 5h`. No fixed boundary; slides with `now`.
/// - `.weekly`   — **fixed**: the start of the next `weekOfYear` interval.
/// - `.monthly`  — **fixed**: the start of the next `month` interval.
///
/// The weekly/monthly boundaries are derived from `Calendar.dateInterval(of:for:)`
/// and advanced by one unit, so DST transitions inside the window do not skew the
/// boundary instant — the calendar arithmetic handles the 23h/25h day for us.
public struct ResetClock: Sendable {
    /// Number of hours in the rolling 5-hour window.
    public static let fiveHourDuration: TimeInterval = 5 * 60 * 60

    /// Calendar driving fixed-boundary math. Defaults to `.current`; injectable
    /// for deterministic tests (fixed timezone + `firstWeekday`).
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The next reset instant for `window`, relative to `now`.
    ///
    /// Falls back to a simple additive estimate if the calendar cannot produce an
    /// interval (never expected for the Gregorian calendar, but keeps the API
    /// non-optional for the UI).
    public func nextReset(for window: BurnWindow, now: Date = Date()) -> Date {
        switch window {
        case .fiveHour:
            return now.addingTimeInterval(Self.fiveHourDuration)

        case .weekly:
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return calendar.date(byAdding: .weekOfYear, value: 1, to: now) ?? now
            }
            // `dateInterval.end` is the exclusive start of the next week — i.e.
            // exactly the next weekly reset boundary.
            return thisWeek.end

        case .monthly:
            guard let thisMonth = calendar.dateInterval(of: .month, for: now) else {
                return calendar.date(byAdding: .month, value: 1, to: now) ?? now
            }
            // `dateInterval.end` is the exclusive start of next month.
            return thisMonth.end
        }
    }

    /// Seconds remaining until the next reset for `window` (never negative).
    public func timeRemaining(for window: BurnWindow, now: Date = Date()) -> TimeInterval {
        max(0, nextReset(for: window, now: now).timeIntervalSince(now))
    }
}
