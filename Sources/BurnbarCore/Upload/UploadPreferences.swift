import Foundation

/// The persisted state of the M3 leaderboard upload pipeline (sub-ticket 3.3.4):
/// the user's opt-in consent flag and the instant of the last successful upload.
///
/// Centralizing these `UserDefaults` keys here (analogous to ``SyncWriteSchedule``
/// for the iCloud writer) is the contract that lets the Settings `Toggle`
/// (`@AppStorage`), the ``UploadScheduler``'s gate, and any "last uploaded" UI all
/// agree on the same two slots. The defaults encode the privacy posture: uploads
/// are **opt-in, default-OFF** (CLAUDE.md M3 — uploads occur only after explicit
/// consent), and "never uploaded" is the absence of a timestamp.
///
/// Pure and view-agnostic so the opt-in gate is unit-testable without launching
/// the app. English-only literals, per the MVP constraint in CLAUDE.md.
public enum UploadPreferences {
    /// `UserDefaults` key for the opt-in consent `Bool`. Absent / `false` means
    /// uploads are disabled; the user must explicitly turn the Settings toggle on.
    public static let optedInKey = "xyz.andybowu.Burnbar.leaderboard.optedIn"

    /// `UserDefaults` key for the timestamp (`Date`) of the last *successful*
    /// upload. Written by the upload path on success; absent until the first one,
    /// which the UI renders as "Never".
    public static let lastUploadAtKey = "xyz.andybowu.Burnbar.leaderboard.last-upload-success-at"

    /// `UserDefaults` key for the signed-in user's public GitHub login, persisted
    /// at sign-in so the "View web profile" link can target `/u/<login>` without a
    /// network round-trip. Only the *public* login is stored — never the token,
    /// never paths or machine ids (CLAUDE.md privacy thesis).
    public static let githubLoginKey = "xyz.andybowu.Burnbar.leaderboard.github-login"

    /// Uploads are off until the user explicitly consents (privacy default).
    public static let optedInByDefault = false

    /// Whether uploads are currently enabled, reading the opt-in flag from
    /// `defaults`. An absent key reads as ``optedInByDefault`` (OFF) — a fresh
    /// install never uploads until the user opts in.
    public static func isOptedIn(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: optedInKey) != nil else {
            return optedInByDefault
        }
        return defaults.bool(forKey: optedInKey)
    }

    /// The instant of the last successful upload, or `nil` if none has succeeded.
    public static func lastUploadAt(in defaults: UserDefaults = .standard) -> Date? {
        // `object(forKey:)` returns nil (not the 1970 epoch) when never set.
        defaults.object(forKey: lastUploadAtKey) as? Date
    }

    /// Record `date` as the instant of the latest successful upload.
    public static func setLastUploadAt(_ date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastUploadAtKey)
    }

    /// The persisted public GitHub login, or `nil` if not signed in / unknown.
    public static func githubLogin(in defaults: UserDefaults = .standard) -> String? {
        guard let login = defaults.string(forKey: githubLoginKey), !login.isEmpty else {
            return nil
        }
        return login
    }
}
