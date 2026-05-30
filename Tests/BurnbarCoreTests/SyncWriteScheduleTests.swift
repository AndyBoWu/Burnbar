import Foundation
import XCTest
@testable import BurnbarCore

/// Pure interval-selection logic for the write scheduler (2.2.4).
final class SyncWriteScheduleTests: XCTestCase {
    func testNilPreferenceSelectsFiveMinuteDefault() {
        XCTAssertEqual(SyncWriteSchedule.interval(for: nil), 5 * 60)
        XCTAssertEqual(SyncWriteSchedule.interval(for: nil), SyncWriteSchedule.defaultInterval)
    }

    func testIntervalTracksRefreshPreference() {
        XCTAssertEqual(SyncWriteSchedule.interval(for: .oneMinute), 60)
        XCTAssertEqual(SyncWriteSchedule.interval(for: .fiveMinutes), 5 * 60)
        XCTAssertEqual(SyncWriteSchedule.interval(for: .fifteenMinutes), 15 * 60)
    }

    func testIntervalMatchesPreferenceSeconds() {
        for preference in RefreshInterval.allCases {
            XCTAssertEqual(
                SyncWriteSchedule.interval(for: preference),
                preference.seconds,
                "interval(for:) must equal the preference's own seconds for \(preference.rawValue)"
            )
        }
    }

    func testLastWriteAtKeyIsNamespaced() {
        XCTAssertEqual(SyncWriteSchedule.lastWriteAtKey, "xyz.andybowu.Burnbar.sync.last-write-at")
    }
}
