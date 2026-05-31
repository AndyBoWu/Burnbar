import BurnbarCore
import SwiftUI

/// The Settings → **Leaderboard** tab (sub-tickets 3.3.4 + #181): the single,
/// self-sufficient place for leaderboard setup — GitHub sign-in, upload consent,
/// and an immediate "Upload now", in that order.
///
/// Before #181 the sign-in row lived in the **Devices** tab while consent +
/// "Upload now" lived here, so a user couldn't tell that the Leaderboard tab
/// needed a Devices-tab sign-in first. Now both live here:
///
/// 1. an **account section** (`LeaderboardAccountSection`) hosting the GitHub
///    device-flow sign-in / signed-in identity / sign out / revoke / delete — the
///    same `AuthController` source of truth that previously backed the Devices
///    row, so there is one session, not two divergent copies.
/// 2. an **opt-in toggle** (`@AppStorage`, default OFF) — the single source of
///    truth the ``UploadScheduler`` and the uploader gate on. Toggling off disables
///    all uploads (the "Upload now" button greys out, and the background scheduler
///    stops via `.burnbarSettingsDidChange`); toggling on arms them.
/// 3. a **"Last uploaded"** row showing the relative time of the last successful
///    upload, or "Never" when unset.
/// 4. an **"Upload now"** button that triggers an immediate aggregate → validate →
///    POST, disabled while opted out, signed out, or an upload is in flight, with
///    an inline reason that explains *why* it's disabled.
/// 5. a **"View web profile"** link opening `https://burnbar.andybowu.xyz/u/<login>`
///    in the default browser (shown only once the public login is known).
///
/// Each uploaded row is only `{ date, provider, tokens, cost_usd }` — the
/// validator (#56) enforces that on every row — tied to your public GitHub
/// identity (`github_id` / `github_login`), which the server reads from your
/// authenticated sign-in (never sent in the row body). The profile link uses only
/// the public GitHub login, never paths or machine ids (CLAUDE.md privacy thesis).
/// English-only literals throughout, per the MVP constraint.
struct LeaderboardSettingsView: View {
    /// The opt-in consent flag — the gate the scheduler/uploader read. Bound to
    /// the toggle; default OFF (privacy posture). Stored under the shared
    /// `UploadPreferences.optedInKey` slot.
    @AppStorage(UploadPreferences.optedInKey) private var optedIn = UploadPreferences.optedInByDefault

    /// Drives the leaderboard "Sign in with GitHub" device flow (3.2.2) — the
    /// single sign-in source of truth for the whole leaderboard setup. The upload
    /// model reads the same Keychain session this controller writes, so the two
    /// never diverge.
    @State private var auth = AuthController()

    /// Owns the "Upload now" action, the last-upload timestamp, and the profile
    /// link target. The opt-in `Bool` itself lives in `@AppStorage` above; the
    /// model reads it (and the Keychain sign-in state) through its injected gates.
    @State private var model = LeaderboardUploadModel()

    /// The canonical "not live yet" readiness line, matching the website's
    /// wording (issue #174) so the app, site, and release notes all read the same.
    /// Accurate to the code: opting in only *saves your preference* and "Upload
    /// now" attempts a live POST — there is no public ranking to land on until the
    /// backend ships (issue #173, operator-gated), and no background auto-upload
    /// runs in this build. When the backend goes live, flip this one string.
    private static let rollingOutStatus =
        "The public leaderboard is rolling out soon. Your opt-in choice is saved now — " +
        "once it's live, your opted-in totals will appear publicly."

    var body: some View {
        Form {
            // Readiness status first: set the expectation that nothing appears
            // publicly yet, while keeping sign-in and opt-in fully usable below.
            Section {
                Label(Self.rollingOutStatus, systemImage: "clock.badge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            LeaderboardAccountSection(auth: auth)

            Section {
                Toggle("Publish to the leaderboard", isOn: $optedIn)

                LabeledContent("Last uploaded") {
                    Text(lastUploadedText)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("Upload now") { model.uploadNow() }
                            .disabled(!canUploadNow)
                        if model.isUploading {
                            ProgressView()
                                .controlSize(.small)
                            Text("Uploading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // When "Upload now" is disabled, say *why* — so the user knows
                    // exactly what to do (sign in / turn on publishing) rather than
                    // staring at a greyed-out button (#181).
                    if let reason = uploadDisabledReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = model.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }

                if let profileURL = model.webProfileURL {
                    Button("View web profile") { model.openWebProfile() }
                        .buttonStyle(.link)
                        .help(profileURL.absoluteString)
                }
            } header: {
                Text("Publishing")
            } footer: {
                Text(
                    "Off by default. When on, each uploaded row is only { date, provider, tokens, cost_usd } — "
                        + "never your prompts, projects, paths, machine ids, or raw model names. Rows are tied to "
                        + "your public GitHub identity (github_id, github_login), read from your sign-in, so they "
                        + "can appear on the public leaderboard."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Toggling opt-in arms/stops the background scheduler (same signal the
        // write scheduler and other Settings controls broadcast).
        .onChange(of: optedIn) { _, _ in
            NotificationCenter.default.post(name: .burnbarSettingsDidChange, object: nil)
        }
        // A completed sign-in/-out flips `auth.state`, which re-renders this view;
        // re-read the model so its Keychain-backed sign-in probe and last-upload
        // timestamp pick up the change (the "Upload now" gate and its reason then
        // reflect the new session).
        .onChange(of: auth.state) { _, _ in model.refresh() }
        // Pick up a timestamp the background scheduler may have advanced since the
        // model was constructed.
        .onAppear { model.refresh() }
    }

    /// Whether "Upload now" is enabled: opted in *and* signed in *and* not already
    /// uploading. Mirrors `LeaderboardUploadModel.canUpload`, but read here so the
    /// disabled state recomputes whenever `auth.state` or `optedIn` change.
    private var canUploadNow: Bool {
        optedIn && isSignedIn && model.canUpload
    }

    /// A plain-English explanation of why "Upload now" is disabled, or `nil` when
    /// it's enabled. Drives the inline caption under the button (#181 acceptance:
    /// the disabled state must explain itself). Checked sign-in first, then consent,
    /// since signing in is the prerequisite users miss most often.
    private var uploadDisabledReason: String? {
        if model.isUploading { return nil }
        if !isSignedIn {
            return "Sign in with GitHub above to upload."
        }
        if !optedIn {
            return "Turn on \"Publish to the leaderboard\" to upload."
        }
        return nil
    }

    /// Whether a GitHub session currently exists, derived from the shared
    /// `auth.state`. Used to gate "Upload now" and pick its disabled reason so the
    /// button and the account row never disagree about being signed in.
    private var isSignedIn: Bool {
        auth.state == .signedIn
    }

    /// "2 hours ago" when an upload has succeeded, else "Never".
    private var lastUploadedText: String {
        guard let date = model.lastUploadAt else { return "Never" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Leaderboard account (3.2.2, relocated here in #181)

/// The leaderboard "Sign in with GitHub" section — now the top of the Leaderboard
/// tab (relocated from the Devices tab in #181 so leaderboard setup lives in one
/// coherent place).
///
/// Tapping "Sign in with GitHub" kicks off GitHub's device flow via
/// `AuthController`: it requests a device code, surfaces the short user code in a
/// large, monospaced, **copyable** label, auto-opens the verification page in the
/// user's default browser, and shows the verification URL as fallback text. While
/// awaiting authorization it polls; on success it stores the token in the Keychain
/// and flips to a signed-in row with a "Sign out" action. Errors surface as a
/// plain-English message with a "Try again" affordance.
///
/// No embedded web view — authorization happens in the system browser, so no
/// cookies or third-party Keychain items are read (privacy thesis, CLAUDE.md M3).
/// English-only literals throughout.
struct LeaderboardAccountSection: View {
    @Bindable var auth: AuthController

    /// Drives the "Revoke access" confirmation dialog. Revocation is irreversible
    /// (it invalidates the token at GitHub), so it is gated behind an explicit
    /// confirm per the 3.2.5 Definition of Done.
    @State private var confirmingRevoke = false

    /// Drives the "Delete all my data" confirmation dialog. Deletion is destructive
    /// and irreversible (it erases the user's server-side leaderboard rows), so it
    /// is gated behind an explicit confirm per the 3.5.2 Definition of Done.
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            switch auth.state {
            case .signedOut:
                signedOutRow

            case .requestingCode:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting GitHub…")
                        .foregroundStyle(.secondary)
                }

            case let .awaitingAuthorization(userCode, verificationURI):
                awaitingRow(userCode: userCode, verificationURI: verificationURI)

            case .signedIn:
                signedInRow

            case let .failed(message):
                failedRow(message: message)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(
                "Sign in to publish your daily totals to the public leaderboard. Each uploaded row is only "
                    + "{ date, provider, tokens, cost_usd }, tied to your public GitHub identity "
                    + "(github_id, github_login) so your row can appear publicly — never your prompts, "
                    + "projects, or paths."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // Revoke is irreversible (invalidates the token at GitHub), so it is gated
        // behind an explicit confirmation per the 3.2.5 Definition of Done.
        .confirmationDialog(
            "Revoke access to GitHub?",
            isPresented: $confirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke access", role: .destructive) {
                Task { await auth.revoke() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This invalidates Burnbar's token at GitHub and signs you out. "
                    + "You'll need to sign in again to publish to the leaderboard."
            )
        }
        // Deleting all data is destructive and irreversible (it erases the user's
        // server-side leaderboard rows), so it is gated behind an explicit
        // confirmation per the 3.5.2 Definition of Done.
        .confirmationDialog(
            "Delete all your leaderboard data?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete all my data", role: .destructive) {
                Task { await auth.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently erases all of your data from the leaderboard and signs you out. "
                    + "This can't be undone. You can sign in again afterwards to start fresh."
            )
        }
    }

    /// The signed-out row leads with an explicit instruction so a first-time user
    /// knows the exact next step (#181 acceptance: the signed-out state must tell
    /// users exactly how to sign in), followed by the sign-in button.
    private var signedOutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "You're not signed in. Click \"Sign in with GitHub\" to authorize in your browser, "
                    + "then turn on publishing below."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Sign in with GitHub") { auth.signIn() }
        }
    }

    private func awaitingRow(userCode: String, verificationURI: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter this code at GitHub to finish signing in:")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(userCode)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button("Copy code") { auth.copyUserCode() }
            }

            // Fallback in case the browser didn't open automatically.
            HStack(spacing: 4) {
                Text("If your browser didn't open,")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("open \(verificationURI)") { auth.openVerificationURL() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var signedInRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Signed in to GitHub", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                // "Sign out" clears only the local Keychain token; "Revoke access"
                // additionally invalidates it at GitHub (behind a confirm).
                Button("Sign out") { auth.signOut() }
                Button("Revoke access", role: .destructive) { confirmingRevoke = true }
            }
            // "Delete all my data" goes further than revoke: it erases the user's
            // server-side leaderboard rows *and* clears local credentials + opt-in
            // (behind a confirm), per the 3.5.2 Definition of Done.
            Button("Delete all my data", role: .destructive) { confirmingDelete = true }
                .help("Permanently erase all your leaderboard data and sign out.")
        }
    }

    private func failedRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
            Button("Try again") { auth.signIn() }
        }
    }
}

#Preview {
    LeaderboardSettingsView()
        .frame(width: 460, height: 300)
}
