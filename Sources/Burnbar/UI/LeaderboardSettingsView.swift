import BurnbarCore
import SwiftUI

/// The Settings → **Leaderboard** tab (sub-ticket 3.3.4): the user's explicit
/// upload consent control plus visibility into upload state.
///
/// Controls, top to bottom:
/// - an **opt-in toggle** (`@AppStorage`, default OFF) — the single source of
///   truth the ``UploadScheduler`` and the uploader gate on. Toggling off disables
///   all uploads (the "Upload now" button greys out, and the background scheduler
///   stops via `.burnbarSettingsDidChange`); toggling on arms them.
/// - a **"Last uploaded"** row showing the relative time of the last successful
///   upload, or "Never" when unset.
/// - an **"Upload now"** button that triggers an immediate aggregate → validate →
///   POST, disabled while opted out, signed out, or an upload is in flight.
/// - a **"View web profile"** link opening `https://burnbar.andybowu.xyz/u/<login>`
///   in the default browser (shown only once the public login is known).
///
/// Only the date, provider, and aggregate token + cost totals ever leave the
/// machine — the validator (#56) enforces that on every row. The profile link uses
/// only the public GitHub login, never paths or machine ids (CLAUDE.md privacy
/// thesis). English-only literals throughout, per the MVP constraint.
struct LeaderboardSettingsView: View {
    /// The opt-in consent flag — the gate the scheduler/uploader read. Bound to
    /// the toggle; default OFF (privacy posture). Stored under the shared
    /// `UploadPreferences.optedInKey` slot.
    @AppStorage(UploadPreferences.optedInKey) private var optedIn = UploadPreferences.optedInByDefault

    /// Owns the "Upload now" action, the last-upload timestamp, and the profile
    /// link target. The opt-in `Bool` itself lives in `@AppStorage` above; the
    /// model reads it through its injected gate.
    @State private var model = LeaderboardUploadModel()

    var body: some View {
        Form {
            Section {
                Toggle("Publish to the leaderboard", isOn: $optedIn)

                LabeledContent("Last uploaded") {
                    Text(lastUploadedText)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Upload now") { model.uploadNow() }
                        .disabled(!optedIn || !model.canUpload)
                    if model.isUploading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Uploading…")
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
                Text("Leaderboard")
            } footer: {
                Text(
                    "Off by default. When on, Burnbar uploads only the date, provider, and your aggregate "
                        + "token and cost totals — never your prompts, projects, or paths. Sign in on the "
                        + "Devices tab first."
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
        // Pick up a timestamp the background scheduler may have advanced since the
        // model was constructed.
        .onAppear { model.refresh() }
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

#Preview {
    LeaderboardSettingsView()
        .frame(width: 460, height: 300)
}
