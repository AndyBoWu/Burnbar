import Foundation
import SQLite3

/// Errors surfaced by ``CodexSQLiteReader``. Every failure mode is typed so
/// callers can react (or ignore-and-degrade) instead of crashing — Burnbar must
/// stay alive even when Codex's database is missing, mid-write, or corrupt.
public enum CodexReaderError: Error, Equatable, Sendable {
    /// No file exists at the resolved database path. Common and benign: the user
    /// simply has not run Codex CLI on this machine.
    case fileNotFound(path: String)

    /// `sqlite3_open_v2` failed. `code` is the raw SQLite result code; `message`
    /// is SQLite's human-readable description (no user content).
    case openFailed(code: Int32, message: String)

    /// Preparing a statement failed (syntax error, missing table, corruption).
    case prepareFailed(code: Int32, message: String)

    /// Stepping a prepared statement failed (e.g. the file is locked or corrupt).
    case stepFailed(code: Int32, message: String)
}

/// One row returned by ``CodexSQLiteReader/query(_:)``: a positional list of
/// column values, plus name→index lookup so callers can read columns by label.
///
/// Values are typed to the four SQLite storage classes Burnbar cares about
/// (`int`, `double`, `text`, `blob`) plus `null`. This is a transport type only;
/// mapping `threads` rows to `UsageRecord` happens in 1.3.2 / 1.3.3.
public struct CodexRow: Sendable, Equatable {
    /// A single SQLite column value, preserving its storage class.
    public enum Value: Sendable, Equatable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null

        /// The value as `Int`, or `nil` if it is not an integer. Convenience for
        /// the 1.3.2 mapping layer reading `tokens_used` / `created_at_ms`.
        public var intValue: Int? {
            if case let .integer(value) = self { return Int(value) }
            return nil
        }

        /// The value as `String`, or `nil` if it is not text. Convenience for the
        /// 1.3.2 mapping layer reading `model` / `day`.
        public var stringValue: String? {
            if case let .text(value) = self { return value }
            return nil
        }
    }

    /// Column values in `SELECT` order.
    public let columns: [Value]

    /// Column name → index, in `SELECT` order. Built once per query and shared
    /// across that query's rows.
    private let columnIndexByName: [String: Int]

    init(columns: [Value], columnIndexByName: [String: Int]) {
        self.columns = columns
        self.columnIndexByName = columnIndexByName
    }

    /// The value at `index`, or `.null` if out of range.
    public subscript(index: Int) -> Value {
        guard index >= 0, index < columns.count else { return .null }
        return columns[index]
    }

    /// The value for a column name, or `nil` if the column is absent from the
    /// result set. Note: a present-but-NULL column returns `.null`, not `nil`.
    public subscript(name: String) -> Value? {
        guard let index = columnIndexByName[name] else { return nil }
        return columns[index]
    }
}

/// Read-only access to Codex's `state_5.sqlite`.
///
/// **Privacy / safety contract** (see docs/data-sources.md + CLAUDE.md):
/// - Opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` and a `?mode=ro` URI, so
///   the connection can never acquire a write lock. While Codex CLI is mid-write
///   (a `-wal`/`-shm` sidecar present), opening read-only still succeeds and
///   never contends the WAL writer.
/// - Exposes **no** `execute`/`write`/`INSERT` surface. The only entry point is
///   ``query(_:)``, which runs a single `SELECT`-style statement and iterates
///   rows. Writes are impossible by construction.
/// - Never runs `PRAGMA journal_mode` (that would attempt a write on the
///   journal). WAL handling is left entirely to SQLite's read path.
///
/// Column-level privacy (the never-read list: `title`, `first_user_message`,
/// `preview`, `cwd`, `git_*`, `rollout_path`) is enforced by the *query* in
/// 1.3.2 — this layer is column-agnostic and only guarantees read-only access.
public final class CodexSQLiteReader: Sendable {
    /// Resolved path to the database file this reader targets.
    public let databasePath: String

    /// Default Codex state database: `~/.codex/state_5.sqlite`, with the home
    /// directory resolved via `FileManager` (no hardcoded `/Users/...`).
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
    }

    /// Creates a reader for the database at `url`. The file is *not* opened here;
    /// each ``query(_:)`` opens and closes its own short-lived read-only
    /// connection, so the reader holds no long-lived handle on Codex's DB.
    ///
    /// - Parameter url: location of the SQLite file. Defaults to
    ///   ``defaultDatabaseURL`` (`~/.codex/state_5.sqlite`).
    public init(url: URL = CodexSQLiteReader.defaultDatabaseURL) {
        databasePath = url.path
    }

    /// Whether the underlying database file currently exists. Cheap pre-check so
    /// callers can distinguish "Codex never ran here" from a real read error.
    public var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    /// Runs a parameterless `SELECT` and returns all rows.
    ///
    /// Opens a fresh read-only connection (`SQLITE_OPEN_READONLY`), prepares and
    /// steps the statement, then closes the connection — even on error. Holds no
    /// write lock at any point, so it is safe to call while Codex CLI runs.
    ///
    /// - Parameter sql: a single read-only SQL statement. Pass trusted,
    ///   parameterless SQL (Burnbar's own `GROUP BY` query in 1.3.2); this method
    ///   takes no bindings.
    /// - Returns: the result rows in result-set order.
    /// - Throws: ``CodexReaderError`` for a missing file, open/prepare/step
    ///   failure (locked, corrupt, etc.).
    public func query(_ sql: String) throws -> [CodexRow] {
        guard databaseExists else {
            throw CodexReaderError.fileNotFound(path: databasePath)
        }

        let handle = try openReadOnly()
        defer { sqlite3_close_v2(handle) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            let message = Self.lastErrorMessage(handle)
            sqlite3_finalize(statement)
            throw CodexReaderError.prepareFailed(code: prepareResult, message: message)
        }
        defer { sqlite3_finalize(statement) }

        let columnIndexByName = Self.columnIndexMap(statement)
        var rows: [CodexRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                rows.append(Self.readRow(statement, columnIndexByName: columnIndexByName))
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw CodexReaderError.stepFailed(
                    code: stepResult,
                    message: Self.lastErrorMessage(handle)
                )
            }
        }
        return rows
    }

    // MARK: - Private

    /// Opens a read-only connection to ``databasePath`` using a `?mode=ro` URI.
    ///
    /// Both belt and suspenders are applied: the `SQLITE_OPEN_READONLY` flag and
    /// the URI `mode=ro` parameter. `immutable=0` is set explicitly so SQLite is
    /// *not* told to ignore the WAL/SHM sidecars — the DB may legitimately change
    /// under us while Codex writes, and we want a consistent read snapshot, not a
    /// stale immutable view.
    private func openReadOnly() throws -> OpaquePointer {
        let encodedPath = Self.percentEncodedPath(databasePath)
        let uri = "file://\(encodedPath)?mode=ro&immutable=0"

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(uri, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map(Self.lastErrorMessage) ?? "unable to open database"
            sqlite3_close_v2(handle)
            throw CodexReaderError.openFailed(code: result, message: message)
        }
        return handle
    }

    /// Percent-encodes a filesystem path for use inside a `file://` SQLite URI,
    /// preserving `/` separators while escaping spaces and other reserved
    /// characters that would otherwise break URI parsing.
    private static func percentEncodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        // SQLite URI parsing treats '?' and '#' as delimiters; keep them escaped
        // (they are not in urlPathAllowed, so this is the default — listed for
        // intent). '/' must survive so directory structure is preserved.
        allowed.insert("/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Builds the column-name → index map for a prepared statement's result set.
    private static func columnIndexMap(_ statement: OpaquePointer) -> [String: Int] {
        let count = Int(sqlite3_column_count(statement))
        var map: [String: Int] = [:]
        map.reserveCapacity(count)
        for index in 0 ..< count {
            if let cName = sqlite3_column_name(statement, Int32(index)) {
                map[String(cString: cName)] = index
            }
        }
        return map
    }

    /// Reads the current row of a stepped statement into a ``CodexRow``.
    private static func readRow(
        _ statement: OpaquePointer,
        columnIndexByName: [String: Int]
    ) -> CodexRow {
        let count = Int(sqlite3_column_count(statement))
        var values: [CodexRow.Value] = []
        values.reserveCapacity(count)
        for index in 0 ..< count {
            values.append(columnValue(statement, index: Int32(index)))
        }
        return CodexRow(columns: values, columnIndexByName: columnIndexByName)
    }

    /// Maps one column of the current row to a typed ``CodexRow/Value``.
    private static func columnValue(_ statement: OpaquePointer, index: Int32) -> CodexRow.Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let cString = sqlite3_column_text(statement, index) {
                return .text(String(cString: cString))
            }
            return .text("")
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, index) {
                let length = Int(sqlite3_column_bytes(statement, index))
                return .blob(Data(bytes: bytes, count: length))
            }
            return .blob(Data())
        default: // SQLITE_NULL
            return .null
        }
    }

    /// SQLite's last error message for a connection, as a Swift string.
    private static func lastErrorMessage(_ handle: OpaquePointer?) -> String {
        guard let handle, let cMessage = sqlite3_errmsg(handle) else {
            return "unknown SQLite error"
        }
        return String(cString: cMessage)
    }
}
