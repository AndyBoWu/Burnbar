import Foundation

/// Pure **schedule math** for the M3 daily leaderboard upload (sub-ticket 3.3.2):
/// when to fire the next daily upload, and how long to wait before retrying a
/// failed one.
///
/// This type deliberately contains **no** I/O, **no** network, **no** `Timer` /
/// `DispatchSourceTimer`, and **no** global clock. It only computes `Date`s and
/// `TimeInterval`s from inputs the caller supplies (`now`, the last upload time,
/// an attempt count, and an injected jitter value). The actual fire-on-a-timer
/// wiring, the opt-in guard, and the HTTP POST to `/api/v1/usage` live in the
/// app-side controller and a later ticket — keeping the arithmetic here pure
/// makes the Definition of Done ("scheduled time within ±30 min of 03:00 local;
/// backoff doubles and caps at 24 h") trivially unit-testable host-free, and the
/// type fully `Sendable`.
///
/// ## Daily anchor
/// The next upload fires at a **03:00 local-time** anchor (`Calendar.current`, so
/// it tracks the user's time zone, including DST shifts), offset by a caller-
/// injected jitter in `[-30 min, +30 min]`. Spreading uploads across a one-hour
/// window keeps every Burnbar install from hammering the backend at the same
/// instant. The jitter is injected as an `Int` seconds value (not drawn from a
/// PRNG inside this type) so tests are deterministic; production callers pass a
/// fresh random value each schedule via ``randomJitterSeconds()``.
///
/// ## Backoff
/// On upload failure, ``backoffDelay(forAttempt:)`` returns an exponentially
/// growing delay (base 60 s, doubling per attempt) hard-capped at 24 h, so a
/// persistently failing backend is retried no more than once a day.
public struct UploadScheduler: Sendable {
    /// The local-time hour the daily upload anchors to (03:00).
    public static let anchorHour = 3

    /// The maximum jitter magnitude applied to the anchor, in seconds (±30 min).
    /// The injected jitter is expected to fall in `[-jitterRangeSeconds,
    /// +jitterRangeSeconds]`; values outside are clamped so a buggy caller can
    /// never push the fire time outside the ±30 min window the DoD guarantees.
    public static let jitterRangeSeconds = 30 * 60

    /// Backoff base delay: the wait before the **first** retry, in seconds (60 s).
    public static let backoffBaseSeconds: TimeInterval = 60

    /// Backoff ceiling: no retry ever waits longer than this (24 h), so a dead
    /// backend is polled at most once per day.
    public static let backoffCapSeconds: TimeInterval = 24 * 60 * 60

    /// The calendar used for the 03:00 local anchor. Defaults to
    /// `Calendar.current` (the user's locale + time zone); injectable so tests
    /// can pin a specific zone without touching global state.
    private let calendar: Calendar

    /// - Parameter calendar: Calendar for the local 03:00 anchor. Defaults to
    ///   `Calendar.current`.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The next daily upload time: the 03:00 local anchor strictly **after**
    /// `now`, shifted by `jitterSeconds`.
    ///
    /// The anchor is chosen so the *jittered* result is always in the future
    /// relative to `now`: it starts at today's 03:00 and rolls forward a day at a
    /// time until `anchor + jitter > now`. This means that even late-night jitter
    /// (e.g. 03:00 yesterday + 29 min when `now` is 03:10) never returns a time in
    /// the past, and a `now` already past today's window correctly lands on
    /// tomorrow.
    ///
    /// `lastUpload` is accepted for API symmetry with the failure path and for
    /// future "don't double-upload within one day" logic; the daily-anchor
    /// computation does not currently depend on it (the strictly-future anchor
    /// already enforces at most one scheduled upload per local day).
    ///
    /// - Parameters:
    ///   - lastUpload: When the last upload happened, if any. Currently advisory.
    ///   - now: The reference instant (injected; never read from a global clock).
    ///   - jitterSeconds: Jitter offset applied to the 03:00 anchor, expected in
    ///     `[-1800, +1800]`. Clamped to that range so the result is guaranteed
    ///     within ±30 min of the anchor.
    /// - Returns: The next jittered 03:00-local upload `Date`, strictly after
    ///   `now`.
    public func nextUploadDate(
        after lastUpload: Date?,
        now: Date,
        jitterSeconds: Int
    ) -> Date {
        _ = lastUpload
        let clampedJitter = min(max(jitterSeconds, -Self.jitterRangeSeconds), Self.jitterRangeSeconds)
        let jitter = TimeInterval(clampedJitter)

        var anchor = anchorDate(onOrBefore: now)
        // Roll forward in whole days until the jittered fire time is in the
        // future. At most two iterations: today's anchor, then tomorrow's.
        while anchor.addingTimeInterval(jitter) <= now {
            guard let next = calendar.date(byAdding: .day, value: 1, to: anchor) else { break }
            anchor = next
        }
        return anchor.addingTimeInterval(jitter)
    }

    /// The backoff delay before retrying upload attempt number `attempt`.
    ///
    /// Exponential with base ``backoffBaseSeconds`` (60 s), doubling per attempt,
    /// hard-capped at ``backoffCapSeconds`` (24 h):
    /// `attempt 0 → 60 s, 1 → 120 s, 2 → 240 s, … then clamped at 24 h`.
    ///
    /// `attempt` is the zero-based retry index (the first retry after the first
    /// failure is `0`). Negative inputs are treated as `0` so a caller that
    /// passes a pre-decremented count still gets the base delay rather than a
    /// sub-base or negative interval.
    ///
    /// - Parameter attempt: Zero-based retry index. Negative values clamp to `0`.
    /// - Returns: Seconds to wait, in `[60, 86400]`.
    public func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(attempt, 0)
        // Cap the exponent before computing the power so very large attempt counts
        // cannot overflow `Double`'s exponent before the min() clamp runs.
        // 2^41 * 60 already exceeds 24 h, so anything past that is the cap anyway.
        let safeExponent = min(exponent, 41)
        let delay = Self.backoffBaseSeconds * pow(2, Double(safeExponent))
        return min(delay, Self.backoffCapSeconds)
    }

    /// A fresh uniformly-random jitter value in `[-1800, +1800]` seconds, for
    /// production callers to pass into ``nextUploadDate(after:now:jitterSeconds:)``.
    ///
    /// Kept separate from `nextUploadDate` so the scheduling arithmetic stays
    /// deterministic and testable; only this helper touches the system RNG.
    public static func randomJitterSeconds() -> Int {
        Int.random(in: -jitterRangeSeconds ... jitterRangeSeconds)
    }

    // MARK: - Anchor

    /// The most recent 03:00 local anchor at or before `reference` — i.e. today's
    /// 03:00 if `reference` is at/after it, else yesterday's.
    ///
    /// Falls back to a raw `anchorHour * 3600` offset only if the calendar cannot
    /// resolve the components (it always can for a valid Gregorian date), so the
    /// function is total.
    private func anchorDate(onOrBefore reference: Date) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = Self.anchorHour
        components.minute = 0
        components.second = 0
        guard let candidate = calendar.date(from: components) else {
            return reference
        }
        if candidate > reference {
            // `reference` is before today's 03:00 → anchor on yesterday's 03:00.
            return calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }
        return candidate
    }
}
