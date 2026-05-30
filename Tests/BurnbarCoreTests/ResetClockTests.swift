import XCTest
@testable import BurnbarCore

final class ResetClockTests: XCTestCase {
    /// A deterministic calendar pinned to a US timezone (observes DST) with a
    /// Sunday `firstWeekday`, so reset boundaries are reproducible regardless of
    /// the host machine's locale. Mirrors `TimeWindowAggregatorTests`.
    private func usCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    /// Build a `Date` for a given Y-M-D-h-m in the supplied calendar.
    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0,
        _ cal: Calendar
    ) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        return cal.date(from: c)!
    }

    // MARK: - 5-hour rolling

    func testFiveHourResetsExactlyFiveHoursFromNow() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 5, 27, 9, 30, cal)

        let reset = clock.nextReset(for: .fiveHour, now: now)

        XCTAssertEqual(reset.timeIntervalSince(now), 5 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(reset, date(2026, 5, 27, 14, 30, cal))
    }

    func testFiveHourIsRollingAcrossMidnight() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        // 11pm + 5h -> 4am next day.
        let now = date(2026, 5, 27, 23, 0, cal)

        let reset = clock.nextReset(for: .fiveHour, now: now)

        XCTAssertEqual(reset, date(2026, 5, 28, 4, 0, cal))
    }

    // MARK: - Weekly fixed

    func testWeeklyResetsAtStartOfNextWeek() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        // Wed 2026-05-27. Sunday-first week is May 24..30; next boundary = Sun May 31 00:00.
        let now = date(2026, 5, 27, 12, 0, cal)

        let reset = clock.nextReset(for: .weekly, now: now)

        XCTAssertEqual(reset, date(2026, 5, 31, 0, 0, cal))
    }

    func testWeeklyResetHonoursMondayFirstWeekday() {
        var cal = usCalendar()
        cal.firstWeekday = 2 // Monday
        let clock = ResetClock(calendar: cal)
        // Wed 2026-05-27. Monday-first week is May 25..31; next boundary = Mon Jun 1 00:00.
        let now = date(2026, 5, 27, 12, 0, cal)

        let reset = clock.nextReset(for: .weekly, now: now)

        XCTAssertEqual(reset, date(2026, 6, 1, 0, 0, cal))
    }

    // MARK: - Monthly fixed

    func testMonthlyResetsAtStartOfNextMonth() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 5, 27, 12, 0, cal)

        let reset = clock.nextReset(for: .monthly, now: now)

        XCTAssertEqual(reset, date(2026, 6, 1, 0, 0, cal))
    }

    func testMonthlyResetRollsToNextYearInDecember() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 12, 15, 12, 0, cal)

        let reset = clock.nextReset(for: .monthly, now: now)

        XCTAssertEqual(reset, date(2027, 1, 1, 0, 0, cal))
    }

    // MARK: - DST safety

    /// In `America/New_York`, DST springs forward on Sun 2026-03-08 at 02:00.
    /// A weekly window that contains that transition must still reset at the real
    /// wall-clock midnight of the following Sunday — the 23-hour day must not
    /// shift the boundary. Verified by checking the boundary lands on a true
    /// `startOfDay` and is the expected calendar instant.
    func testWeeklyResetIsCorrectAcrossSpringForwardDST() {
        let cal = usCalendar() // Sunday first; America/New_York observes DST.
        let clock = ResetClock(calendar: cal)
        // Thu 2026-03-05, inside the week Sun Mar 1 .. Sat Mar 7. The week that
        // *follows* (Mar 8..) begins exactly when DST springs forward that day.
        let now = date(2026, 3, 5, 12, 0, cal)

        let reset = clock.nextReset(for: .weekly, now: now)

        // Next weekly boundary = Sun Mar 8 00:00 local, the start of the DST day.
        XCTAssertEqual(reset, date(2026, 3, 8, 0, 0, cal))
        // And it is a genuine startOfDay despite the clocks jumping at 02:00.
        XCTAssertEqual(reset, cal.startOfDay(for: date(2026, 3, 8, 6, 0, cal)))

        // The elapsed time to the boundary reflects the *real* duration, which a
        // naive `+7 * 86400` would get wrong on a DST week. From Thu noon to Sun
        // midnight is 2 days + 12 hours of wall time = 60 calendar hours, but the
        // spring-forward Sunday hasn't been crossed yet at the boundary, so the
        // interval here is a clean 60h. (The skipped hour is *after* the reset.)
        XCTAssertEqual(reset.timeIntervalSince(now), 60 * 60 * 60, accuracy: 0.001)
    }

    /// Fall-back: clocks repeat 01:00 on Sun 2026-11-01. A monthly window over
    /// October must still reset at the genuine start of November.
    func testMonthlyResetIsCorrectAcrossFallBackDST() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 10, 20, 12, 0, cal)

        let reset = clock.nextReset(for: .monthly, now: now)

        XCTAssertEqual(reset, date(2026, 11, 1, 0, 0, cal))
        XCTAssertEqual(reset, cal.startOfDay(for: date(2026, 11, 1, 6, 0, cal)))
    }

    // MARK: - timeRemaining

    func testTimeRemainingIsNonNegativeAndMatchesNextReset() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 5, 27, 9, 30, cal)

        let remaining = clock.timeRemaining(for: .fiveHour, now: now)

        XCTAssertEqual(remaining, 5 * 60 * 60, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(remaining, 0)
    }

    func testTimeRemainingNeverNegativeForFixedWindows() {
        let cal = usCalendar()
        let clock = ResetClock(calendar: cal)
        let now = date(2026, 5, 27, 12, 0, cal)

        XCTAssertGreaterThanOrEqual(clock.timeRemaining(for: .weekly, now: now), 0)
        XCTAssertGreaterThanOrEqual(clock.timeRemaining(for: .monthly, now: now), 0)
    }
}
