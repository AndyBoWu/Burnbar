import Foundation

// =============================================================================
// SyncHealth (2.5.2) — pure, view-agnostic verdict on whether this machine's
// iCloud rollup is keeping up.
//
// The write scheduler (2.2.4) rewrites `{machine_id}.jsonl` on a 5-minute
// cadence and persists `last-write-at` (`SyncWriteSchedule.lastWriteAtKey`) only
// on a successful write. A write can fail, or iCloud Drive can be disabled, and
// then the combined cross-device view silently goes stale. This type maps
// `(lastWriteAt, iCloudAvailable, now)` to a verdict the Settings → Devices tab
// renders: either a quiet "Last sync …" status, or a warning when the data is
// stale so the user doesn't trust a lagging combined total.
//
// Lives in `BurnbarCore` (not the app target) so the threshold + phrasing are
// unit-testable host-free; the SwiftUI display stays in `SettingsView`.
//
// English-only literals throughout, per the MVP constraint in CLAUDE.md.
// =============================================================================

/// Whether this machine's iCloud rollup is fresh enough to trust.
public enum SyncStatus: Equatable, Sendable {
    /// The last successful write is recent (within the stale threshold) and
    /// iCloud is reachable — no warning needed.
    case ok
    /// Sync has gone stale: the last write is older than the threshold, iCloud
    /// is unavailable, or no write has ever succeeded. The combined view may be
    /// behind, so the user is warned.
    case stale
}

/// Pure verdict on this machine's sync freshness for the Devices settings tab
/// (2.5.2). Computed from the `last-write-at` timestamp the 2.2.4 scheduler
/// persists and whether iCloud Drive is currently reachable.
public struct SyncHealth: Equatable, Sendable {
    /// The default staleness threshold: 30 minutes. The write cadence is 5
    /// minutes (``SyncWriteSchedule/defaultInterval``), so a gap past 30 minutes
    /// (six missed writes) indicates a real lag, not normal timer jitter — per
    /// the ticket.
    public static let defaultStaleThreshold: TimeInterval = 30 * 60

    /// `.ok` when fresh and reachable; `.stale` otherwise.
    public let status: SyncStatus

    /// Whole minutes since the last successful write, or `nil` when no write has
    /// ever succeeded. Clamped at `0` so a `lastWriteAt` slightly in the future
    /// (clock skew) never reads negative.
    public let staleByMinutes: Int?

    /// The quiet status line always shown for this Mac, e.g. "Last sync 2 minutes
    /// ago" or "Never synced". Reuses ``LastSyncedDisplay`` phrasing so the
    /// relative wording matches the rest of the tab.
    public let statusLabel: String

    /// The warning line shown only when ``status`` is `.stale`; `nil` when `.ok`
    /// so the view hides the row. Explains why sync is behind.
    public let warningLabel: String?

    /// `true` when the warning row should be shown.
    public var isStale: Bool { status == .stale }

    public init(
        status: SyncStatus,
        staleByMinutes: Int?,
        statusLabel: String,
        warningLabel: String?
    ) {
        self.status = status
        self.staleByMinutes = staleByMinutes
        self.statusLabel = statusLabel
        self.warningLabel = warningLabel
    }

    /// Evaluate sync health.
    ///
    /// - Parameters:
    ///   - lastWriteAt: The instant of this machine's last successful rollup
    ///     write (`SyncWriteSchedule.lastWriteAtKey`), or `nil` if none yet.
    ///   - iCloudAvailable: Whether iCloud Drive is currently reachable
    ///     (`ICloudLocation.isAvailable`). When `false`, sync is stale regardless
    ///     of the timestamp.
    ///   - now: "Now" reference, injectable for deterministic tests.
    ///   - threshold: How old the last write may be before it counts as stale
    ///     (default 30 minutes — ``defaultStaleThreshold``).
    ///   - locale: Locale for the relative phrasing, injectable for tests.
    /// - Returns: the computed ``SyncHealth``.
    public static func evaluate(
        lastWriteAt: Date?,
        iCloudAvailable: Bool,
        now: Date = Date(),
        threshold: TimeInterval = defaultStaleThreshold,
        locale: Locale = .current
    ) -> SyncHealth {
        let statusLabel = LastSyncedDisplay.text(for: lastWriteAt, relativeTo: now, locale: locale)

        // No successful write ever recorded: stale, with no minute delta to show.
        guard let lastWriteAt else {
            return SyncHealth(
                status: .stale,
                staleByMinutes: nil,
                statusLabel: statusLabel,
                warningLabel: noWriteWarning(iCloudAvailable: iCloudAvailable)
            )
        }

        // Clamp negative ages (clock skew) to 0 so "in the future" never reads as
        // a negative delta.
        let age = max(0, now.timeIntervalSince(lastWriteAt))
        let minutes = Int(age / 60)

        // iCloud being down forces stale even if the last write was recent: the
        // remote file can no longer be updated, so the data is at risk of lag.
        let exceedsThreshold = age > threshold
        guard exceedsThreshold || !iCloudAvailable else {
            return SyncHealth(
                status: .ok,
                staleByMinutes: minutes,
                statusLabel: statusLabel,
                warningLabel: nil
            )
        }

        return SyncHealth(
            status: .stale,
            staleByMinutes: minutes,
            statusLabel: statusLabel,
            warningLabel: staleWarning(minutes: minutes, iCloudAvailable: iCloudAvailable)
        )
    }

    // MARK: - Warning copy

    /// Warning when a write has happened but is now stale. When iCloud is
    /// unavailable the cause is called out; otherwise the minute delta is shown.
    private static func staleWarning(minutes: Int, iCloudAvailable: Bool) -> String {
        if !iCloudAvailable {
            return "iCloud Drive unavailable — last sync \(minutesPhrase(minutes)) ago."
        }
        return "Sync is behind — last sync \(minutesPhrase(minutes)) ago."
    }

    /// Warning when no write has ever succeeded.
    private static func noWriteWarning(iCloudAvailable: Bool) -> String {
        iCloudAvailable
            ? "Not synced yet — this Mac hasn't written to iCloud."
            : "iCloud Drive unavailable — this Mac hasn't synced."
    }

    /// "N minute"/"N minutes" with correct singular/plural; "less than a minute"
    /// for a sub-minute delta so the warning never reads "0 minutes".
    private static func minutesPhrase(_ minutes: Int) -> String {
        switch minutes {
        case ..<1: return "less than a minute"
        case 1: return "1 minute"
        default: return "\(minutes) minutes"
        }
    }
}
