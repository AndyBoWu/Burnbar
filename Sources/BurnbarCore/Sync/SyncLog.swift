import Foundation

// =============================================================================
// SyncLog (2.5.3) — a tiny, privacy-safe append-only diagnostic log for sync
// operations.
//
// The manual "Force resync" action (Settings → Devices) writes this machine's
// rollup and re-reads every machine on demand. When sync looks stale, the user
// (or a maintainer reading a bug report) needs a record of what happened: when a
// resync started, whether the write landed, how many machines were read, how
// long it took, and any error code. This helper appends one structured line per
// event to `~/Library/Logs/Burnbar/sync.log` (the conventional macOS user-log
// location), creating the directory on first use.
//
// PRIVACY (load-bearing, per CLAUDE.md): a sync-log line records only
// timing / ids / counts / status — never `message.content`, `first_user_message`,
// `preview`, `title`, `cwd`, `git_*`, project dir names, or any filesystem path
// outside the Burnbar sync dir. Callers compose the structured detail; this type
// only timestamps and appends it, so the allowlist is enforced at the call site
// (and asserted by the tests).
//
// TESTABILITY: the base directory is injected. Production resolves
// `~/Library/Logs`; tests pass a temp directory so they never touch the real
// user Logs folder. The append is best-effort and never throws — diagnostics
// must not be able to break a resync.
// =============================================================================

/// Append-only, timestamped diagnostic log for sync operations (2.5.3).
///
/// `Sendable` and value-typed: holds only an immutable base-directory URL and a
/// clock closure, so it is safe to share across the resync's concurrency
/// boundaries. Logging is best-effort — a failed append is swallowed so a full
/// disk or a permissions hiccup can never sink a resync.
public struct SyncLog: Sendable {
    /// The directory that *contains* the `Burnbar/` log folder. Production:
    /// `~/Library/Logs`. Tests inject a temp directory.
    private let baseDirectory: URL
    /// Injected clock so tests assert a deterministic, parseable timestamp.
    private let now: @Sendable () -> Date
    /// Performs the actual append. Injected so tests can run entirely in memory
    /// if they wish; defaults to a real file append.
    private let appendLine: @Sendable (_ line: String, _ file: URL) -> Void

    /// The `Logs/Burnbar/` sub-directory under ``baseDirectory`` where the log
    /// file lives.
    public var directory: URL {
        baseDirectory.appendingPathComponent("Burnbar", isDirectory: true)
    }

    /// The full path of `sync.log`.
    public var fileURL: URL {
        directory.appendingPathComponent("sync.log", isDirectory: false)
    }

    /// - Parameters:
    ///   - baseDirectory: the folder that holds the `Burnbar/` log directory.
    ///     Defaults to `~/Library/Logs` (the standard macOS user-log location).
    ///     **Tests must pass a temp directory** so they never write to the real
    ///     Logs folder.
    ///   - now: clock for line timestamps (default: `Date()`).
    ///   - appendLine: the append primitive (default: a real, directory-creating
    ///     file append). Injected only for tests that want to avoid the disk.
    public init(
        baseDirectory: URL = SyncLog.defaultBaseDirectory(),
        now: @escaping @Sendable () -> Date = { Date() },
        appendLine: @escaping @Sendable (_ line: String, _ file: URL) -> Void = SyncLog.defaultAppend
    ) {
        self.baseDirectory = baseDirectory
        self.now = now
        self.appendLine = appendLine
    }

    /// `~/Library/Logs` — the conventional location for user-visible app logs on
    /// macOS. Resolved from the current user's home directory.
    public static func defaultBaseDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    /// Append one structured line to `sync.log`, prefixed with an ISO-8601 UTC
    /// timestamp.
    ///
    /// The resulting line is `"<iso8601-utc> <detail>\n"`. `detail` is the
    /// caller-composed, privacy-safe structured payload (e.g.
    /// `"force-resync wrote=true machines=3 duration_ms=420"`). Best-effort:
    /// directory creation or the append failing is swallowed, never thrown.
    public func append(_ detail: String) {
        let line = "\(Self.timestamp(now())) \(detail)\n"
        appendLine(line, fileURL)
    }

    // MARK: - Formatting

    /// ISO-8601 UTC timestamp (e.g. `2026-05-30T14:03:22Z`) — fixed, locale- and
    /// timezone-independent so log lines are stable and machine-parseable.
    static func timestamp(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    /// Configured once at init and never mutated afterwards, so sharing it across
    /// concurrency domains is safe; `ISO8601DateFormatter` itself is documented
    /// thread-safe for formatting.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Default append

    /// The production append: create the `Burnbar/` log directory if absent, then
    /// append `line`'s UTF-8 bytes to `file` (creating it if needed). All failures
    /// are swallowed — logging must never break a resync.
    public static let defaultAppend: @Sendable (_ line: String, _ file: URL) -> Void = { line, file in
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            // Existing file: seek to end and append.
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // No file yet: create it with this first line.
            try? data.write(to: file, options: .atomic)
        }
    }
}
