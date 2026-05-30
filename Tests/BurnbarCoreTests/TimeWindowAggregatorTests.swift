import XCTest
@testable import BurnbarCore

final class TimeWindowAggregatorTests: XCTestCase {
    /// A deterministic calendar pinned to a US timezone (observes DST) with a
    /// Sunday firstWeekday, so bucket boundaries are reproducible regardless of
    /// the host machine's locale.
    private func usCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    /// Build a `Date` at local noon for a given Y-M-D in the supplied calendar.
    private func noon(_ year: Int, _ month: Int, _ day: Int, _ cal: Calendar) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = 12
        return cal.date(from: c)!
    }

    private func record(
        _ provider: Provider,
        _ model: String,
        _ day: String,
        input: Int,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheCreation: Int? = nil,
        cost: Double? = nil
    ) -> UsageRecord {
        UsageRecord(
            provider: provider,
            model: model,
            day: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            costUSD: cost
        )
    }

    // MARK: - Bucket boundaries

    func testTodayBucketIncludesOnlyTodayRecords() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        // "now" = Wed 2026-05-27 noon. Week (Sun-Sat) = May 24..30; month = May.
        let now = noon(2026, 5, 27, cal)

        let records = [
            record(.claude, "claude-opus-4-7", "2026-05-27", input: 100, output: 10, cost: 1.0), // today
            record(.claude, "claude-opus-4-7", "2026-05-26", input: 200, output: 20, cost: 2.0), // this week, not today
            record(.codex, "gpt-5", "2026-05-01", input: 50, cost: 0.5), // this month, not week
            record(.claude, "claude-sonnet-4-6", "2026-04-30", input: 999, cost: 9.99) // prior month, in none
        ]

        let result = agg.aggregate(records, now: now)

        let today = result[.today]!
        XCTAssertEqual(today.inputTokens, 100)
        XCTAssertEqual(today.outputTokens, 10)
        XCTAssertEqual(today.costUSD, 1.0, accuracy: 1e-9)
        XCTAssertEqual(today.totalTokens, 110)
    }

    func testWeekBucketAlignsWithCalendarWeek() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal) // week = Sun May 24 .. Sat May 30

        let records = [
            record(.claude, "m", "2026-05-23", input: 1), // Sat before — excluded
            record(.claude, "m", "2026-05-24", input: 10), // Sun — included (week start)
            record(.claude, "m", "2026-05-27", input: 100), // today — included
            record(.claude, "m", "2026-05-30", input: 1000), // Sat — included (week end)
            record(.claude, "m", "2026-05-31", input: 1) // next Sun — excluded
        ]

        let week = agg.aggregate(records, window: .week, now: now)
        XCTAssertEqual(week.inputTokens, 10 + 100 + 1000)
    }

    func testMonthBucketAlignsWithCalendarMonth() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal)

        let records = [
            record(.claude, "m", "2026-04-30", input: 1), // April — excluded
            record(.claude, "m", "2026-05-01", input: 10), // month start — included
            record(.claude, "m", "2026-05-31", input: 1000), // month end — included
            record(.claude, "m", "2026-06-01", input: 1) // June — excluded
        ]

        let month = agg.aggregate(records, window: .month, now: now)
        XCTAssertEqual(month.inputTokens, 10 + 1000)
    }

    func testRecordCanLandInMultipleWindows() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal)

        // A single "today" record should appear in today, week, and month.
        let records = [record(.claude, "m", "2026-05-27", input: 100, output: 50, cost: 3.0)]
        let result = agg.aggregate(records, now: now)

        for window in TimeWindow.allCases {
            XCTAssertEqual(result[window]!.inputTokens, 100, "\(window) should include today's record")
            XCTAssertEqual(result[window]!.outputTokens, 50)
            XCTAssertEqual(result[window]!.costUSD, 3.0, accuracy: 1e-9)
        }
    }

    // MARK: - Sums & nil handling

    func testNilTokenAndCostFieldsTreatedAsZero() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal)

        // Codex record: only inputTokens, no cost yet.
        let records = [record(.codex, "gpt-5", "2026-05-27", input: 4200)]
        let today = agg.aggregate(records, window: .today, now: now)

        XCTAssertEqual(today.inputTokens, 4200)
        XCTAssertEqual(today.outputTokens, 0)
        XCTAssertEqual(today.cacheReadTokens, 0)
        XCTAssertEqual(today.cacheCreationTokens, 0)
        XCTAssertEqual(today.costUSD, 0.0, accuracy: 1e-9)
        XCTAssertEqual(today.totalTokens, 4200)
    }

    func testEmptyInputProducesEmptyAggregatesForEveryWindow() {
        let agg = TimeWindowAggregator(calendar: usCalendar())
        let result = agg.aggregate([])
        XCTAssertEqual(result.count, TimeWindow.allCases.count)
        for window in TimeWindow.allCases {
            let bucket = result[window]!
            XCTAssertEqual(bucket.totalTokens, 0)
            XCTAssertEqual(bucket.costUSD, 0.0, accuracy: 1e-9)
            XCTAssertTrue(bucket.byProvider.isEmpty)
            XCTAssertTrue(bucket.byModel.isEmpty)
        }
    }

    // MARK: - Breakdowns

    func testProviderAndModelBreakdowns() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal)

        let records = [
            record(.claude, "claude-opus-4-7", "2026-05-27", input: 100, output: 10, cost: 1.0),
            record(.claude, "claude-opus-4-7", "2026-05-27", input: 50, output: 5, cost: 0.5),
            record(.codex, "gpt-5", "2026-05-27", input: 300, cost: 2.0)
        ]

        let today = agg.aggregate(records, window: .today, now: now)

        // Totals.
        XCTAssertEqual(today.inputTokens, 450)
        XCTAssertEqual(today.outputTokens, 15)
        XCTAssertEqual(today.costUSD, 3.5, accuracy: 1e-9)

        // Per-provider.
        XCTAssertEqual(today.byProvider[.claude]?.inputTokens, 150)
        XCTAssertEqual(today.byProvider[.claude]?.outputTokens, 15)
        XCTAssertEqual(today.byProvider[.claude]?.costUSD ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(today.byProvider[.codex]?.inputTokens, 300)
        XCTAssertEqual(today.byProvider[.codex]?.costUSD ?? -1, 2.0, accuracy: 1e-9)

        // Per-model (the two opus records collapse into one model row).
        XCTAssertEqual(today.byModel["claude-opus-4-7"]?.inputTokens, 150)
        XCTAssertEqual(today.byModel["claude-opus-4-7"]?.provider, .claude)
        XCTAssertEqual(today.byModel["gpt-5"]?.inputTokens, 300)
        XCTAssertEqual(today.byModel["gpt-5"]?.provider, .codex)
        XCTAssertEqual(today.byModel.count, 2)
    }

    // MARK: - DST transitions

    func testSpringForwardDayDoesNotDrift() {
        // US spring-forward 2026: 02:00 -> 03:00 on Sun 2026-03-08; 00:00 exists.
        // Anchoring the day at noon must keep 2026-03-08 in *its own* today bucket
        // and out of 2026-03-07 / 2026-03-09.
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 3, 8, cal)

        let records = [
            record(.claude, "m", "2026-03-07", input: 1),
            record(.claude, "m", "2026-03-08", input: 10),
            record(.claude, "m", "2026-03-09", input: 100)
        ]

        let today = agg.aggregate(records, window: .today, now: now)
        XCTAssertEqual(today.inputTokens, 10, "spring-forward day must bucket only its own records")

        // And the week interval must still be a real 7 calendar-day span even
        // though one day is 23h long.
        let week = agg.windowIntervals(now: now)[.week]!
        let days = cal.dateComponents([.day], from: week.start, to: week.end).day
        XCTAssertEqual(days, 7, "week spanning a spring-forward day is still 7 calendar days")
    }

    func testFallBackDayDoesNotDrift() {
        // US fall-back 2026: 02:00 -> 01:00 on Sun 2026-11-01; 01:00 occurs twice.
        // Noon anchoring keeps the day unambiguous.
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 11, 1, cal)

        let records = [
            record(.claude, "m", "2026-10-31", input: 1),
            record(.claude, "m", "2026-11-01", input: 10),
            record(.claude, "m", "2026-11-02", input: 100)
        ]

        let today = agg.aggregate(records, window: .today, now: now)
        XCTAssertEqual(today.inputTokens, 10, "fall-back day must bucket only its own records")

        let week = agg.windowIntervals(now: now)[.week]!
        let days = cal.dateComponents([.day], from: week.start, to: week.end).day
        XCTAssertEqual(days, 7, "week spanning a fall-back day is still 7 calendar days")
    }

    // MARK: - Boundary instant: very start / end of today

    func testStartOfDayInstantIsIncludedInToday() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        // now = exactly local midnight of 2026-05-27.
        let startOfToday = cal.startOfDay(for: noon(2026, 5, 27, cal))

        let records = [record(.claude, "m", "2026-05-27", input: 42)]
        let today = agg.aggregate(records, window: .today, now: startOfToday)
        XCTAssertEqual(today.inputTokens, 42, "the day matching the start-of-day instant is today")
    }

    // MARK: - Malformed day strings

    func testMalformedDayStringIsSkipped() {
        let cal = usCalendar()
        let agg = TimeWindowAggregator(calendar: cal)
        let now = noon(2026, 5, 27, cal)

        let records = [
            record(.claude, "m", "not-a-date", input: 5),
            record(.claude, "m", "2026-05-27", input: 7)
        ]
        let today = agg.aggregate(records, window: .today, now: now)
        XCTAssertEqual(today.inputTokens, 7, "malformed day strings are skipped, valid ones still count")
    }
}
