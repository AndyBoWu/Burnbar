import Foundation

/// One day's per-model token totals as recorded in `stats-cache.json`'s
/// `dailyModelTokens` array.
///
/// `tokensByModel` maps a raw model id (e.g. `claude-opus-4-7`) to a single
/// aggregate token count for `date`. Claude Code does **not** break this daily
/// number into input/output/cache here — that finer breakdown only exists in the
/// lifetime `modelUsage` totals (see ``ModelUsage``). The per-day numbers are
/// what Burnbar uses for the historical daily timeline; the lifetime breakdown
/// informs ratios/cost weighting in later epics.
public struct DailyModelTokens: Codable, Sendable, Equatable {
    /// Local calendar day, formatted `YYYY-MM-DD`, exactly as Claude Code writes
    /// it. Used verbatim as the daily bucket key (matches `UsageRecord.day`).
    public let date: String

    /// Raw model id → aggregate token count for `date`. Verbatim model ids;
    /// pricing/variant resolution happens later in `CostCalculator` (Epic 1.4).
    public let tokensByModel: [String: Int]

    public init(date: String, tokensByModel: [String: Int]) {
        self.date = date
        self.tokensByModel = tokensByModel
    }
}

/// Lifetime (all-time) token breakdown for a single model, from the
/// `modelUsage` object in `stats-cache.json`.
///
/// These are cumulative totals across the cache's whole history, not per-day.
/// Only the four token fields plus `webSearchRequests` are decoded; Claude Code
/// also writes derived fields (e.g. `costUSD`, `contextWindow`) that Burnbar
/// deliberately ignores — Burnbar computes cost itself from `PricingTable`
/// (Epic 1.4) rather than trusting the cache's number.
public struct ModelUsage: Codable, Sendable, Equatable {
    /// Lifetime input (prompt) tokens for this model.
    public let inputTokens: Int

    /// Lifetime output (completion) tokens for this model.
    public let outputTokens: Int

    /// Lifetime cache-read input tokens for this model.
    public let cacheReadInputTokens: Int

    /// Lifetime cache-creation input tokens for this model.
    public let cacheCreationInputTokens: Int

    /// Lifetime count of server-side web search requests. Not a token field;
    /// kept because the schema exposes it and it may inform tool-cost later.
    public let webSearchRequests: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        webSearchRequests: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.webSearchRequests = webSearchRequests
    }
}

/// Typed, decoded view of `~/.claude/stats-cache.json` (schema version 3).
///
/// This is a pure data container — only the aggregate fields Burnbar needs are
/// modeled; everything else in the file (`dailyActivity`, `hourCounts`,
/// `totalSessions`, …) is intentionally left undecoded. The cache holds
/// **aggregates only** (no prompts, no responses), and covers history through
/// ``lastComputedDate`` (typically yesterday); today's tokens are not here and
/// are picked up from the JSONL delta in a later sub-ticket (1.2.2).
public struct StatsCache: Codable, Sendable, Equatable {
    /// Schema version. Burnbar targets version 3; ``StatsCacheReader`` warns on
    /// a mismatch but still attempts a best-effort decode.
    public let version: Int

    /// Last day Claude Code computed the cache through, formatted `YYYY-MM-DD`.
    /// Everything up to and including this date is covered by the cache;
    /// "today" is not (it lives only in the per-session JSONL until recomputed).
    public let lastComputedDate: String?

    /// Per-day, per-model aggregate token counts — the historical daily timeline.
    public let dailyModelTokens: [DailyModelTokens]

    /// Lifetime per-model token breakdown, keyed by raw model id.
    public let modelUsage: [String: ModelUsage]

    public init(
        version: Int,
        lastComputedDate: String?,
        dailyModelTokens: [DailyModelTokens],
        modelUsage: [String: ModelUsage]
    ) {
        self.version = version
        self.lastComputedDate = lastComputedDate
        self.dailyModelTokens = dailyModelTokens
        self.modelUsage = modelUsage
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case lastComputedDate
        case dailyModelTokens
        case modelUsage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        lastComputedDate = try container.decodeIfPresent(String.self, forKey: .lastComputedDate)
        // Both collections are optional in practice: a brand-new install may have
        // written the cache header before any usage accrued. Treat absent as empty
        // rather than failing the whole decode.
        dailyModelTokens = try container.decodeIfPresent([DailyModelTokens].self, forKey: .dailyModelTokens) ?? []
        modelUsage = try container.decodeIfPresent([String: ModelUsage].self, forKey: .modelUsage) ?? [:]
    }
}

/// Reads and decodes Claude Code's pre-aggregated token cache,
/// `~/.claude/stats-cache.json` (schema version 3).
///
/// This is the **primary historical source** for the Claude parser (Epic 1.2)
/// and the foundation the rest of the epic builds on. The cache is maintained by
/// Claude Code itself and holds **aggregates only** — per-day/per-model token
/// counts and lifetime per-model breakdowns. It contains **no prompts and no
/// responses**, so it is safe to read in full.
///
/// Privacy boundary (see docs/data-sources.md): this reader touches **only**
/// `stats-cache.json`. It never reads `~/.claude/history.jsonl`,
/// `~/.claude/sessions/`, `~/.claude/auth.json`, or any `message.content` /
/// `text` field. It models only the four aggregate fields named in the schema.
///
/// The cache covers history through ``StatsCache/lastComputedDate`` (typically
/// yesterday); today's delta is scanned separately from the per-session JSONL in
/// sub-ticket 1.2.2 and merged in 1.2.4.
///
/// No `UsageRecord` mapping happens here — this reader's sole job is a safe,
/// typed decode. Mapping to the unified model lands in a later sub-ticket.
public struct StatsCacheReader: Sendable {
    /// Schema version Burnbar is written against.
    public static let expectedVersion = 3

    /// Absolute path to the cache file. Defaults to `~/.claude/stats-cache.json`,
    /// resolved from the user's home directory via `FileManager` (never a
    /// hardcoded `/Users/...`). Overridable for tests/fixtures.
    public let fileURL: URL

    /// Default home-relative location of the cache.
    ///
    /// Uses `FileManager.default` (a process-wide singleton, safe to call here)
    /// to resolve the home directory — never a hardcoded `/Users/...` path.
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("stats-cache.json", isDirectory: false)
    }

    /// - Parameter fileURL: cache location. Defaults to
    ///   `~/.claude/stats-cache.json`.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
    }

    /// Why a read failed. Distinguishes "no cache yet" (an expected, recoverable
    /// state on a fresh machine) from a genuinely corrupt/unreadable file.
    public enum ReadError: Error, Equatable, CustomStringConvertible {
        /// The cache file does not exist at ``StatsCacheReader/fileURL``.
        case fileNotFound(URL)
        /// The file exists but could not be read or JSON-decoded.
        case decodingFailed(String)

        public var description: String {
            switch self {
            case let .fileNotFound(url):
                return "stats-cache.json not found at \(url.path)"
            case let .decodingFailed(detail):
                return "failed to decode stats-cache.json: \(detail)"
            }
        }
    }

    /// Loads and decodes the cache into a typed ``StatsCache``.
    ///
    /// - Asserts schema `version == 3`; on mismatch it logs a warning and still
    ///   returns a best-effort decode rather than crashing (forward/backward
    ///   compatibility — the aggregate fields rarely move between versions).
    /// - A missing file throws ``ReadError/fileNotFound(_:)`` so callers can
    ///   degrade to "no history yet" instead of crashing. For a non-throwing
    ///   variant that maps the missing case to an empty result, use
    ///   ``readOrEmpty()``.
    ///
    /// - Returns: the decoded cache (aggregates only).
    /// - Throws: ``ReadError`` on a missing or undecodable file.
    public func read() throws -> StatsCache {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReadError.fileNotFound(fileURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw ReadError.decodingFailed("could not read file: \(error.localizedDescription)")
        }

        let cache: StatsCache
        do {
            cache = try JSONDecoder().decode(StatsCache.self, from: data)
        } catch {
            throw ReadError.decodingFailed(String(describing: error))
        }

        if cache.version != Self.expectedVersion {
            // Warn but don't fail: the four aggregate fields we decode are stable
            // across the schema versions we've observed. Surfacing this lets us
            // notice a real breaking change without taking the app down.
            FileHandle.standardError.write(
                Data(
                    "[Burnbar] warning: stats-cache.json version \(cache.version) != expected \(Self.expectedVersion); decoding best-effort.\n"
                        .utf8
                )
            )
        }

        return cache
    }

    /// Convenience wrapper that treats a missing cache file as an empty cache
    /// (version 3, no days, no models) rather than throwing.
    ///
    /// A genuinely corrupt/unreadable file still throws — that's an error worth
    /// surfacing, whereas "no cache yet" is a normal fresh-install state.
    public func readOrEmpty() throws -> StatsCache {
        do {
            return try read()
        } catch ReadError.fileNotFound {
            return StatsCache(
                version: Self.expectedVersion,
                lastComputedDate: nil,
                dailyModelTokens: [],
                modelUsage: [:]
            )
        }
    }
}
