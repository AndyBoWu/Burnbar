import XCTest
@testable import BurnbarCore

/// Tests for the Devices tab's stale-sync verdict (2.5.2).
///
/// These feed synthetic `lastWriteAt` / iCloud-availability values to
/// ``SyncHealth/evaluate(lastWriteAt:iCloudAvailable:now:threshold:locale:)`` and
/// assert the status, the `staleByMinutes` delta, and the warning copy —
/// including the 30-minute boundary and the clear-on-resync transition the
/// Definition of Done requires.
final class SyncHealthTests: XCTestCase {
    /// Deterministic "now" so relative phrasing and deltas are stable regardless
    /// of the host clock.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Deterministic English (US) locale for the relative status phrasing.
    private let enUS = Locale(identifier: "en_US")

    private func evaluate(lastWriteAt: Date?, iCloudAvailable: Bool = true) -> SyncHealth {
        SyncHealth.evaluate(
            lastWriteAt: lastWriteAt,
            iCloudAvailable: iCloudAvailable,
            now: now,
            locale: enUS
        )
    }

    // MARK: - Fresh / OK

    func testRecentWriteIsOK() {
        let twoMinutesAgo = now.addingTimeInterval(-2 * 60)
        let health = evaluate(lastWriteAt: twoMinutesAgo)

        XCTAssertEqual(health.status, .ok)
        XCTAssertFalse(health.isStale)
        XCTAssertEqual(health.staleByMinutes, 2)
        XCTAssertNil(health.warningLabel)
        XCTAssertFalse(health.statusLabel.isEmpty)
        XCTAssertNotEqual(health.statusLabel, LastSyncedDisplay.neverSyncedText)
    }

    func testWriteJustNowIsOK() {
        let health = evaluate(lastWriteAt: now)
        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual(health.staleByMinutes, 0)
        XCTAssertNil(health.warningLabel)
    }

    /// Clock skew: a `lastWriteAt` slightly in the future must never read a
    /// negative delta or flip to stale.
    func testFutureTimestampClampsToZeroAndStaysOK() {
        let future = now.addingTimeInterval(90)
        let health = evaluate(lastWriteAt: future)
        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual(health.staleByMinutes, 0)
        XCTAssertNil(health.warningLabel)
    }

    // MARK: - Threshold boundary (30 min)

    func testExactlyThirtyMinutesIsStillOK() {
        // Boundary: 30 min is the threshold; `age > threshold` is strict, so
        // exactly 30 minutes is NOT yet stale.
        let thirtyMinutesAgo = now.addingTimeInterval(-30 * 60)
        let health = evaluate(lastWriteAt: thirtyMinutesAgo)
        XCTAssertEqual(health.status, .ok)
        XCTAssertEqual(health.staleByMinutes, 30)
        XCTAssertNil(health.warningLabel)
    }

    func testJustPastThirtyMinutesIsStale() {
        let pastThreshold = now.addingTimeInterval(-(30 * 60 + 1))
        let health = evaluate(lastWriteAt: pastThreshold)
        XCTAssertEqual(health.status, .stale)
        XCTAssertTrue(health.isStale)
        XCTAssertEqual(health.staleByMinutes, 30)
        XCTAssertEqual(health.warningLabel, "Sync is behind — last sync 30 minutes ago.")
    }

    func testWellPastThresholdReportsActualDelta() {
        let fortyFiveMinutesAgo = now.addingTimeInterval(-45 * 60)
        let health = evaluate(lastWriteAt: fortyFiveMinutesAgo)
        XCTAssertEqual(health.status, .stale)
        XCTAssertEqual(health.staleByMinutes, 45)
        XCTAssertEqual(health.warningLabel, "Sync is behind — last sync 45 minutes ago.")
    }

    // MARK: - iCloud unavailable

    func testICloudUnavailableIsStaleEvenWithRecentWrite() {
        // A recent write but iCloud is down: still stale, because the remote file
        // can no longer advance.
        let twoMinutesAgo = now.addingTimeInterval(-2 * 60)
        let health = evaluate(lastWriteAt: twoMinutesAgo, iCloudAvailable: false)
        XCTAssertEqual(health.status, .stale)
        XCTAssertEqual(health.staleByMinutes, 2)
        XCTAssertEqual(health.warningLabel, "iCloud Drive unavailable — last sync 2 minutes ago.")
    }

    func testICloudUnavailableSubMinuteUsesLessThanAMinute() {
        let health = evaluate(lastWriteAt: now, iCloudAvailable: false)
        XCTAssertEqual(health.status, .stale)
        XCTAssertEqual(health.warningLabel, "iCloud Drive unavailable — last sync less than a minute ago.")
    }

    // MARK: - Never synced

    func testNilLastWriteIsStaleWithNoDelta() {
        let health = evaluate(lastWriteAt: nil)
        XCTAssertEqual(health.status, .stale)
        XCTAssertNil(health.staleByMinutes)
        XCTAssertEqual(health.statusLabel, LastSyncedDisplay.neverSyncedText)
        XCTAssertEqual(health.warningLabel, "Not synced yet — this Mac hasn't written to iCloud.")
    }

    func testNilLastWriteWithICloudDownCallsOutICloud() {
        let health = evaluate(lastWriteAt: nil, iCloudAvailable: false)
        XCTAssertEqual(health.status, .stale)
        XCTAssertNil(health.staleByMinutes)
        XCTAssertEqual(health.warningLabel, "iCloud Drive unavailable — this Mac hasn't synced.")
    }

    // MARK: - Singular phrasing

    func testOneMinutePastThresholdUsesSingularMinute() {
        // Push the warning's minute delta to exactly 1 by using a tiny threshold,
        // so we exercise the singular branch deterministically.
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let health = SyncHealth.evaluate(
            lastWriteAt: oneMinuteAgo,
            iCloudAvailable: true,
            now: now,
            threshold: 1,
            locale: enUS
        )
        XCTAssertEqual(health.status, .stale)
        XCTAssertEqual(health.staleByMinutes, 1)
        XCTAssertEqual(health.warningLabel, "Sync is behind — last sync 1 minute ago.")
    }

    // MARK: - Clear on resync (DoD)

    func testWarningClearsAfterSuccessfulResync() {
        // Stale before resync.
        let stale = evaluate(lastWriteAt: now.addingTimeInterval(-40 * 60))
        XCTAssertEqual(stale.status, .stale)
        XCTAssertNotNil(stale.warningLabel)

        // A fresh write lands; re-evaluating with the new timestamp clears it.
        let resynced = evaluate(lastWriteAt: now.addingTimeInterval(-10))
        XCTAssertEqual(resynced.status, .ok)
        XCTAssertNil(resynced.warningLabel)
        XCTAssertEqual(resynced.staleByMinutes, 0)
    }
}
