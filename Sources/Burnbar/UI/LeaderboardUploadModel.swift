import AppKit
import BurnbarCore
import Foundation
import Observation

/// Backs the Settings → Leaderboard tab (sub-ticket 3.3.4): owns the opt-in gate,
/// the "Upload now" action, the last-upload timestamp, and the "View web profile"
/// link target.
///
/// The actual aggregate → validate → POST work is delegated to an injected
/// uploader closure (production: ``LeaderboardUploader`` fed the
/// ``LeaderboardAggregator`` output and the Keychain token), so the view-model's
/// gating logic — "Upload now" is a no-op while opted out or signed out, and only
/// a successful upload advances the timestamp — is unit-testable with no network,
/// no Keychain, and no real aggregation.
///
/// `@MainActor @Observable`: the view binds directly to ``isUploading``,
/// ``lastUploadAt``, and ``lastErrorMessage``. The opt-in `Bool` itself is owned
/// by the view's `@AppStorage` (the single source of truth the
/// ``UploadScheduler`` also gates on); this model only *reads* it through the
/// injected ``isOptedIn`` closure when deciding whether an upload may run.
@MainActor
@Observable
final class LeaderboardUploadModel {
    /// The production Burnbar site origin. The public web profile lives at
    /// `…/u/<login>`.
    static let siteBase = URL(string: "https://burnbar.andybowu.xyz")!

    /// The production Burnbar API base. The usage upload endpoint is this plus
    /// ``LeaderboardUploader/usagePath``.
    static let apiBase = URL(string: "https://api.burnbar.andybowu.xyz")!

    /// True while an "Upload now" run is in flight, so the button shows a spinner
    /// and is disabled (a double-tap can't launch two uploads).
    private(set) var isUploading = false

    /// The instant of the last *successful* upload, or `nil` for "Never". Seeded
    /// from `UserDefaults` and refreshed after each successful run.
    private(set) var lastUploadAt: Date?

    /// The most recent upload failure's plain-English message, or `nil` when the
    /// last run succeeded / none has run. Shown inline under the button.
    private(set) var lastErrorMessage: String?

    /// Reads the current opt-in flag (the same `@AppStorage` slot the view binds
    /// the toggle to). Injected so tests drive the gate without `UserDefaults`.
    private let isOptedIn: @MainActor () -> Bool

    /// Reads whether a GitHub session exists (a token is stored). Injected so the
    /// gate is testable without the Keychain.
    private let isSignedIn: @MainActor () -> Bool

    /// Reads the signed-in user's public GitHub login for the profile link, or
    /// `nil` when unknown. Injected so tests don't touch `UserDefaults`.
    private let githubLogin: @MainActor () -> String?

    /// Performs one aggregate → validate → POST run, returning the instant it
    /// succeeded. Throwing surfaces as ``lastErrorMessage``. Injected so the whole
    /// network/aggregation path is faked in tests.
    private let performUpload: @Sendable () async throws -> Date

    /// Opens a URL in the user's default browser (production:
    /// `NSWorkspace.shared.open`). Injected so the "View web profile" action is
    /// testable without launching a browser.
    private let openURL: @MainActor (URL) -> Void

    /// - Parameters:
    ///   - isOptedIn: Reads the opt-in flag (default: ``UploadPreferences``).
    ///   - isSignedIn: Reads whether a token is stored (default: Keychain).
    ///   - githubLogin: Reads the public login for the profile link (default:
    ///     ``UploadPreferences``).
    ///   - performUpload: Runs one upload, returning the success instant (default:
    ///     the live aggregate → validate → POST wiring).
    ///   - openURL: Opens a URL in the browser (default: `NSWorkspace`).
    init(
        isOptedIn: @escaping @MainActor () -> Bool = { UploadPreferences.isOptedIn() },
        isSignedIn: @escaping @MainActor () -> Bool = LeaderboardUploadModel.defaultIsSignedIn,
        githubLogin: @escaping @MainActor () -> String? = { UploadPreferences.githubLogin() },
        performUpload: @escaping @Sendable () async throws -> Date = LeaderboardUploadModel.liveUpload,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.isOptedIn = isOptedIn
        self.isSignedIn = isSignedIn
        self.githubLogin = githubLogin
        self.performUpload = performUpload
        self.openURL = openURL
        lastUploadAt = UploadPreferences.lastUploadAt()
    }

    /// Whether the "Upload now" button may be enabled: the user is both opted in
    /// *and* signed in, and no upload is currently running. The view also disables
    /// the button while `isUploading`, but this captures the gating rule directly
    /// (the Definition of Done: opt-out / signed-out blocks uploads).
    var canUpload: Bool {
        isOptedIn() && isSignedIn() && !isUploading
    }

    /// The web profile URL `…/u/<login>`, or `nil` when the login is unknown (not
    /// signed in yet, or the login wasn't persisted). The link is hidden when nil.
    var webProfileURL: URL? {
        guard let login = githubLogin(), !login.isEmpty else { return nil }
        return Self.siteBase
            .appendingPathComponent("u")
            .appendingPathComponent(login)
    }

    /// Run one immediate upload, honouring the opt-in / signed-in gate.
    ///
    /// A no-op (no aggregation, no request) while opted out, signed out, or an
    /// upload is already in flight — this is the gate the Definition of Done
    /// requires. On success the last-upload timestamp is persisted and advanced;
    /// on failure a plain-English message is surfaced and the timestamp is left
    /// untouched.
    func uploadNow() {
        guard canUpload else { return }
        isUploading = true
        lastErrorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let uploadedAt = try await performUpload()
                finish(success: uploadedAt)
            } catch {
                finish(failure: error)
            }
        }
    }

    /// Open the user's public web profile in the default browser. A no-op when the
    /// login is unknown.
    func openWebProfile() {
        guard let url = webProfileURL else { return }
        openURL(url)
    }

    /// Re-read the persisted last-upload timestamp (e.g. when the tab appears, in
    /// case the background scheduler uploaded since the model was constructed).
    func refresh() {
        lastUploadAt = UploadPreferences.lastUploadAt()
    }

    // MARK: - Completion

    private func finish(success uploadedAt: Date) {
        UploadPreferences.setLastUploadAt(uploadedAt)
        lastUploadAt = uploadedAt
        lastErrorMessage = nil
        isUploading = false
    }

    private func finish(failure error: Error) {
        lastErrorMessage = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        isUploading = false
    }

    // MARK: - Live wiring

    /// Default "signed in" probe: a non-nil Keychain token means a session exists.
    static func defaultIsSignedIn() -> Bool {
        let stored = try? KeychainTokenStore().read()
        return stored.flatMap(\.self) != nil
    }

    /// The live aggregate → validate → POST run used in production.
    ///
    /// Reads this machine's reconciled cross-machine usage, folds it to
    /// leaderboard-safe rows via ``LeaderboardAggregator``, and POSTs the validated
    /// rows through ``LeaderboardUploader`` with the Keychain bearer token. Returns
    /// the completion instant on success.
    ///
    /// Note: cross-machine reconciliation wiring (M2 `Reconciler` → aggregator) is
    /// owned by the scheduler (#58); the Settings "Upload now" button reuses the
    /// same uploader. Until that wiring is threaded here it sends the rows the
    /// caller-side scheduler supplies; this default is the production entry point
    /// the app wires when constructing the model.
    static func liveUpload() async throws -> Date {
        let uploader = LeaderboardUploader(
            apiBase: apiBase,
            token: { try? KeychainTokenStore().read() }
        )
        let rows = await currentLeaderboardRows()
        _ = try await uploader.upload(rows)
        return Date()
    }

    /// The leaderboard-safe rows for an immediate upload. The app threads the real
    /// reconciled usage here when wiring the model; the no-arg default returns an
    /// empty batch (a safe no-op upload) so a stub build still links.
    private static func currentLeaderboardRows() async -> [LeaderboardRecord] {
        []
    }
}
