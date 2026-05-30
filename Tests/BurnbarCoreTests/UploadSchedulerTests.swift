import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``UploadScheduler`` — the pure schedule math for the M3 daily
/// upload. Two independent guarantees from the Definition of Done:
///
/// 1. **Next-upload window:** the scheduled fire time lands within ±30 min of
///    03:00 local across a range of `now` values (before/after the daily window,
///    and across a US spring-forward DST day), and is always strictly in the
///    future. Jitter is injected for determinism and clamped to the ±30 min band.
/// 2. **Backoff:** delays double from a 60 s base, clamp at 24 h, and `attempt 0`
///    yields the base (negative attempts also clamp to the base).
///
/// All inputs (clock, jitter, calendar/time zone) are injected — no global clock,
/// no network, no `Timer`.
final class UploadSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    /// A scheduler pinned to a fixed time zone so the 03:00 "local" anchor is
    /// deterministic regardless of where the test host runs.
    private func scheduler(timeZone identifier: String = "America/New_York") -> UploadScheduler {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return UploadScheduler(calendar: calendar)
    }

    /// Build a `Date` from local wall-clock components in `identifier`'s zone.
    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone identifier: String = "America/New_York"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// Assert `fireDate` is within ±30 min of an 03:00 anchor on *some* local day
    /// in `identifier`'s zone (i.e. its local time of day is within [02:30, 03:30]).
    private func assertWithinAnchorWindow(
        _ fireDate: Date,
        timeZone identifier: String = "America/New_York",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        let anchor = calendar.date(
            bySettingHour: UploadScheduler.anchorHour,
            minute: 0,
            second: 0,
            of: fireDate
        )!
        let delta = abs(fireDate.timeIntervalSince(anchor))
        XCTAssertLessThanOrEqual(
            delta,
            TimeInterval(UploadScheduler.jitterRangeSeconds),
            "fire time \(fireDate) is more than ±30 min from its 03:00 local anchor",
            file: file,
            line: line
        )
    }

    // MARK: - Next-upload window

    func testFiresTomorrowWhenNowIsAfterTodaysWindow() {
        let sut = scheduler()
        // 10:00 local — today's 03:00 window is long gone.
        let now = date(2026, 5, 30, 10, 0)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 0)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        // With zero jitter the fire time is exactly tomorrow 03:00 local.
        XCTAssertEqual(fire, date(2026, 5, 31, 3, 0))
    }

    func testFiresTodayWhenNowIsBeforeTodaysWindow() {
        let sut = scheduler()
        // 00:30 local — before today's 03:00, so today's anchor is still ahead.
        let now = date(2026, 5, 30, 0, 30)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 0)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        XCTAssertEqual(fire, date(2026, 5, 30, 3, 0))
    }

    func testPositiveJitterShiftsLater() {
        let sut = scheduler()
        let now = date(2026, 5, 30, 0, 30)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 25 * 60)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        // 03:00 + 25 min = 03:25 local.
        XCTAssertEqual(fire, date(2026, 5, 30, 3, 25))
    }

    func testNegativeJitterShiftsEarlier() {
        let sut = scheduler()
        let now = date(2026, 5, 30, 0, 30)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: -25 * 60)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        // 03:00 - 25 min = 02:35 local.
        XCTAssertEqual(fire, date(2026, 5, 30, 2, 35))
    }

    func testJitterIsClampedToThirtyMinutes() {
        let sut = scheduler()
        let now = date(2026, 5, 30, 0, 30)
        // Absurd jitter must clamp to +30 min, never pushing outside the window.
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 10 * 60 * 60)

        assertWithinAnchorWindow(fire)
        XCTAssertEqual(fire, date(2026, 5, 30, 3, 30))
    }

    func testNowInsideWindowStillReturnsFutureTime() {
        let sut = scheduler()
        // 03:10 local with -29 min jitter would put the *earliest* candidate at
        // 02:41 today (already past). The scheduler must roll to tomorrow.
        let now = date(2026, 5, 30, 3, 10)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: -29 * 60)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        // Tomorrow 02:31 local (03:00 - 29 min).
        XCTAssertEqual(fire, date(2026, 5, 31, 2, 31))
    }

    /// Several `now` values in a row: every result is strictly future and inside
    /// the ±30 min window, for a spread of jitter values.
    func testWindowHoldsAcrossManyNowValues() {
        let sut = scheduler()
        let nows = [
            date(2026, 1, 1, 0, 0),
            date(2026, 1, 1, 3, 0),
            date(2026, 1, 1, 12, 0),
            date(2026, 1, 1, 23, 59),
            date(2026, 6, 15, 2, 45),
            date(2026, 12, 31, 23, 0)
        ]
        let jitters = [-1800, -900, -1, 0, 1, 900, 1800]
        for now in nows {
            for jitter in jitters {
                let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: jitter)
                XCTAssertGreaterThan(fire, now, "fire must be after now=\(now) jitter=\(jitter)")
                assertWithinAnchorWindow(fire)
            }
        }
    }

    // MARK: - DST

    /// US spring-forward 2026 is 2026-03-08 (clocks jump 02:00 → 03:00 local).
    /// The 03:00 anchor must still resolve and the fire time stay strictly future
    /// and within the window despite the missing hour.
    func testAnchorSurvivesSpringForwardDST() {
        let sut = scheduler(timeZone: "America/New_York")
        // The night before spring-forward.
        let now = date(2026, 3, 7, 23, 0)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 0)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        // Next 03:00 local is on the spring-forward day itself.
        XCTAssertEqual(fire, date(2026, 3, 8, 3, 0))
    }

    /// US fall-back 2026 is 2026-11-01 (clocks repeat 01:00 → 01:00). 03:00 is
    /// unaffected, but verify the scheduler stays correct around it.
    func testAnchorSurvivesFallBackDST() {
        let sut = scheduler(timeZone: "America/New_York")
        let now = date(2026, 10, 31, 22, 0)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 0)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire)
        XCTAssertEqual(fire, date(2026, 11, 1, 3, 0))
    }

    func testWindowHoldsInNonUSTimeZone() {
        let zone = "Europe/Berlin"
        let sut = scheduler(timeZone: zone)
        let now = date(2026, 5, 30, 14, 0, timeZone: zone)
        let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: 600)

        XCTAssertGreaterThan(fire, now)
        assertWithinAnchorWindow(fire, timeZone: zone)
        XCTAssertEqual(fire, date(2026, 5, 31, 3, 10, timeZone: zone))
    }

    // MARK: - Backoff

    func testBackoffAttemptZeroIsBaseDelay() {
        let sut = scheduler()
        XCTAssertEqual(sut.backoffDelay(forAttempt: 0), 60)
    }

    func testBackoffNegativeAttemptClampsToBase() {
        let sut = scheduler()
        XCTAssertEqual(sut.backoffDelay(forAttempt: -5), 60)
    }

    func testBackoffDoublesEachAttempt() {
        let sut = scheduler()
        let expected: [TimeInterval] = [
            60, // 2^0 * 60
            120, // 2^1
            240, // 2^2
            480, // 2^3
            960, // 2^4
            1920, // 2^5
            3840, // 2^6
            7680 // 2^7
        ]
        for (attempt, want) in expected.enumerated() {
            XCTAssertEqual(
                sut.backoffDelay(forAttempt: attempt),
                want,
                "attempt \(attempt) should be \(want)s"
            )
        }
    }

    func testBackoffIsMonotonicNonDecreasing() {
        let sut = scheduler()
        var previous = sut.backoffDelay(forAttempt: 0)
        for attempt in 1 ... 60 {
            let current = sut.backoffDelay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(current, previous, "backoff must never shrink (attempt \(attempt))")
            previous = current
        }
    }

    func testBackoffCapsAtTwentyFourHours() {
        let sut = scheduler()
        let cap: TimeInterval = 24 * 60 * 60
        // 2^10 * 60 = 61_440s < 24h; 2^11 * 60 = 122_880s > 24h, so it clamps.
        XCTAssertEqual(sut.backoffDelay(forAttempt: 10), 61_440)
        XCTAssertEqual(sut.backoffDelay(forAttempt: 11), cap)
        // Far past the cap (and past the internal exponent guard) stays clamped.
        XCTAssertEqual(sut.backoffDelay(forAttempt: 50), cap)
        XCTAssertEqual(sut.backoffDelay(forAttempt: 1_000_000), cap)
    }

    func testBackoffNeverExceedsCap() {
        let sut = scheduler()
        let cap: TimeInterval = 24 * 60 * 60
        for attempt in 0 ... 100 {
            XCTAssertLessThanOrEqual(sut.backoffDelay(forAttempt: attempt), cap)
        }
    }

    // MARK: - Random jitter helper

    func testRandomJitterStaysWithinRange() {
        for _ in 0 ..< 1000 {
            let jitter = UploadScheduler.randomJitterSeconds()
            XCTAssertGreaterThanOrEqual(jitter, -UploadScheduler.jitterRangeSeconds)
            XCTAssertLessThanOrEqual(jitter, UploadScheduler.jitterRangeSeconds)
        }
    }

    func testRandomJitterFedBackProducesInWindowTime() {
        let sut = scheduler()
        let now = date(2026, 7, 4, 18, 0)
        for _ in 0 ..< 200 {
            let jitter = UploadScheduler.randomJitterSeconds()
            let fire = sut.nextUploadDate(after: nil, now: now, jitterSeconds: jitter)
            XCTAssertGreaterThan(fire, now)
            assertWithinAnchorWindow(fire)
        }
    }
}
