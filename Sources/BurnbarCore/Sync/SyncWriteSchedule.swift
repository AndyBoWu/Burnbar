import Foundation

// =============================================================================
// SyncWriteSchedule (2.2.4) — pure, view-agnostic scheduling constants and the
// timer-interval selection used by the app-side write scheduler.
//
// The write scheduler (`SyncWriteController`, app target) keeps this machine's
// `{machine_id}.jsonl` iCloud rollup fresh by writing on a repeating timer, on
// app quit, and on system wake. The cadence is derived from the user's
// refresh-rate preference (General → Refresh rate, 1.5.6) so the rollup is
// rewritten as often as the menu-bar total refreshes — falling back to 5 minutes
// (the ticket's default) when no preference is stored.
//
// This lives in `BurnbarCore` (not the app target) so the interval selection is
// unit-testable host-free; the AppKit `Timer`/notification wiring stays in the
// thin app shell.
// =============================================================================

/// Pure scheduling helpers for the iCloud write scheduler (2.2.4).
public enum SyncWriteSchedule {
    /// `UserDefaults` key the timestamp of the last successful rollup write is
    /// persisted under. Defined here (centrally) so the writer and any UI that
    /// surfaces "last synced" agree on one slot, per the ticket.
    public static let lastWriteAtKey = "xyz.andybowu.Burnbar.sync.last-write-at"

    /// The fallback cadence when no refresh-rate preference is stored: 5 minutes,
    /// matching the ticket ("every 5 minutes while running").
    public static let defaultInterval: TimeInterval = 5 * 60

    /// The repeating-timer interval, in seconds, for a given refresh-rate
    /// preference. A `nil` preference (none stored yet) selects
    /// ``defaultInterval`` (5 minutes).
    ///
    /// The write cadence intentionally tracks the read cadence: when the user
    /// picks a faster refresh rate the rollup is rewritten more often, so a
    /// second Mac sees near-current data sooner.
    public static func interval(for preference: RefreshInterval?) -> TimeInterval {
        guard let preference else { return defaultInterval }
        return preference.seconds
    }
}
