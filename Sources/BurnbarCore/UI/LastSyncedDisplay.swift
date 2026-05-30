import Foundation

/// Pure, view-agnostic rendering of a "Last synced" timestamp for the Devices
/// settings tab (2.1.3).
///
/// In 2.1.3 the Devices tab shows *this* Mac with a "Last synced" row that is a
/// placeholder until Epic 2.2 (the iCloud write scheduler / WriteController)
/// records a real timestamp. Rather than scatter the placeholder literal and the
/// date formatting across the SwiftUI view, this enum owns the mapping from an
/// optional `Date` to the exact English string the row displays — so 2.2.x can
/// hand it a real timestamp without touching the view, and the formatting is
/// unit-testable without launching the app.
///
/// English-only literals throughout, per the MVP constraint in CLAUDE.md.
public enum LastSyncedDisplay {
    /// The string shown when no sync has happened yet (no timestamp recorded).
    /// Used both before Epic 2.2 lands and afterwards for a fresh install that
    /// has never written a rollup.
    public static let neverSyncedText = "Never"

    /// Render a "Last synced" value for display.
    ///
    /// - Parameters:
    ///   - date: The last successful sync time, or `nil` if none has occurred.
    ///   - relativeTo: "Now" reference for the relative phrasing (injectable for
    ///     deterministic tests). Defaults to the current date.
    ///   - locale: Locale for the formatter (injectable for deterministic tests).
    ///     Defaults to the current locale.
    /// - Returns: ``neverSyncedText`` when `date` is `nil`, otherwise a
    ///   human-readable relative description (e.g. "2 minutes ago").
    public static func text(
        for date: Date?,
        relativeTo reference: Date = Date(),
        locale: Locale = .current
    ) -> String {
        guard let date else { return neverSyncedText }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
