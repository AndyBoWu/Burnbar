import Foundation

/// One aggregated row from Burnbar's Codex query: the total `tokens_used` for a
/// single `(day, model)` bucket in `~/.codex/state_5.sqlite`'s `threads` table.
///
/// **Token granularity caveat (consumed in 1.3.3):** Codex stores only a single
/// `tokens_used` integer per thread — there is **no** breakdown into
/// input / output / cache_read / cache_create. So `tokens` here is an opaque
/// total. When mapped to ``UsageRecord`` (1.3.3), it becomes `inputTokens` and
/// the other token fields stay `nil`; the UI renders this Codex asymmetry
/// (total-only tile) versus Claude's stacked breakdown.
public struct CodexDailyModelTokens: Sendable, Equatable {
    /// Local calendar day for this bucket, formatted `YYYY-MM-DD`, as produced by
    /// SQLite's `DATE(created_at_ms / 1000, 'unixepoch')`. Used verbatim as the
    /// daily bucket key (matches ``UsageRecord/day``).
    public let day: String

    /// Raw Codex model id (e.g. `gpt-5`), or `"unknown"` when the thread's `model`
    /// column was `NULL` (via SQL `COALESCE(model, 'unknown')`). Pricing/variant
    /// resolution happens later in `CostCalculator` (Epic 1.4).
    public let model: String

    /// Sum of `tokens_used` across every thread in this `(day, model)` bucket.
    /// A single opaque total — see the type-level caveat.
    public let tokens: Int

    public init(day: String, model: String, tokens: Int) {
        self.day = day
        self.model = model
        self.tokens = tokens
    }
}

/// Errors surfaced by ``CodexThreadsReader/dailyModelTokens()``.
///
/// Wraps the underlying ``CodexReaderError`` from the read-only SQLite helper
/// (1.3.1) for open/prepare/step failures, and adds a typed case for a result
/// row whose projected columns are not the expected SQLite storage classes.
public enum CodexThreadsReaderError: Error, Sendable {
    /// The read-only SQLite layer failed (missing file, open/prepare/step error).
    case reader(CodexReaderError)

    /// A returned row did not have the expected `day TEXT`, `model TEXT`,
    /// `tokens INTEGER` shape. Carries the 0-based result-row index for triage.
    /// Should not happen given Burnbar's fixed query, but is surfaced rather than
    /// silently dropped (never silently drop — see CLAUDE.md).
    case malformedRow(index: Int)
}

/// Runs Burnbar's single aggregation query against Codex's `threads` table and
/// returns daily per-model token totals.
///
/// This is the **one and only** SQL Burnbar issues against Codex. The query
/// projects exactly three columns — `day` (derived from `created_at_ms`),
/// `model`, and `SUM(tokens_used)` — and is defined as a constant matching
/// docs/data-sources.md verbatim.
///
/// **Privacy contract (data-sources.md + CLAUDE.md):** the `SELECT` must never
/// reference the ⚠ content/path columns `title`, `first_user_message`,
/// `preview`, `cwd`, `git_sha`, `git_branch`, `git_origin_url`, or
/// `rollout_path` — they leak user prompts or filesystem layout. Read-only
/// access (`?mode=ro`) and write-lock safety are guaranteed by the underlying
/// ``CodexSQLiteReader`` (1.3.1); this layer only chooses the columns.
///
/// `UsageRecord` mapping is **not** done here — that is 1.3.3.
public struct CodexThreadsReader: Sendable {
    /// The exact aggregation SQL, verbatim from docs/data-sources.md
    /// ("Burnbar's Codex query"). The only columns read are the three projected
    /// here plus `created_at_ms` (timestamp) in the derivation/filter — never any
    /// content or path column.
    public static let aggregationSQL = """
    SELECT
      DATE(created_at_ms / 1000, 'unixepoch') AS day,
      COALESCE(model, 'unknown') AS model,
      SUM(tokens_used) AS tokens
    FROM threads
    WHERE created_at_ms IS NOT NULL
    GROUP BY day, model
    ORDER BY day DESC;
    """

    /// Column name for the derived day bucket in ``aggregationSQL``.
    private static let dayColumn = "day"
    /// Column name for the coalesced model in ``aggregationSQL``.
    private static let modelColumn = "model"
    /// Column name for the summed token total in ``aggregationSQL``.
    private static let tokensColumn = "tokens"

    /// The read-only SQLite helper (1.3.1) this reader queries through.
    private let reader: CodexSQLiteReader

    /// Creates a threads reader over the given read-only SQLite helper.
    ///
    /// - Parameter reader: a ``CodexSQLiteReader``. Defaults to one targeting
    ///   `~/.codex/state_5.sqlite`.
    public init(reader: CodexSQLiteReader = CodexSQLiteReader()) {
        self.reader = reader
    }

    /// The resolved path to the Codex database being read. Convenience pass-through
    /// for diagnostics/UI; does not open the file.
    public var databasePath: String { reader.databasePath }

    /// Whether the underlying Codex database file currently exists. Cheap pre-check
    /// so callers can distinguish "Codex never ran here" from a real read error.
    public var databaseExists: Bool { reader.databaseExists }

    /// Executes ``aggregationSQL`` and decodes each result row into a
    /// ``CodexDailyModelTokens``.
    ///
    /// - Returns: one entry per `(day, model)` bucket, ordered by `day` descending
    ///   (the query's `ORDER BY day DESC`). An empty database, an empty `threads`
    ///   table, or a `threads` table with only `NULL` `created_at_ms` rows all
    ///   yield an **empty array** — not an error.
    /// - Throws: ``CodexThreadsReaderError/reader(_:)`` if the read-only layer
    ///   fails (missing file, open/prepare/step error), or
    ///   ``CodexThreadsReaderError/malformedRow(index:)`` if a row is not the
    ///   expected `TEXT, TEXT, INTEGER` shape.
    public func dailyModelTokens() throws -> [CodexDailyModelTokens] {
        let rows: [CodexRow]
        do {
            rows = try reader.query(Self.aggregationSQL)
        } catch let error as CodexReaderError {
            throw CodexThreadsReaderError.reader(error)
        }

        return try rows.enumerated().map { index, row in
            // COALESCE(model, 'unknown') guarantees a non-NULL text model; a NULL
            // `model` column surfaces as the literal "unknown" from SQLite itself.
            guard
                let day = row[Self.dayColumn]?.stringValue,
                let model = row[Self.modelColumn]?.stringValue,
                let tokens = row[Self.tokensColumn]?.intValue
            else {
                throw CodexThreadsReaderError.malformedRow(index: index)
            }
            return CodexDailyModelTokens(day: day, model: model, tokens: tokens)
        }
    }
}
