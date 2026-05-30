import Foundation

/// Merges Claude Code's historical token cache with today's live JSONL delta into
/// a single stream of ``UsageRecord``s (`provider == .claude`).
///
/// This is the capstone of the Claude parser (Epic 1.2): it stitches together the
/// two halves built earlier in the epic —
///
/// - ``StatsCacheReader`` (1.2.1) reads `~/.claude/stats-cache.json`, the
///   pre-aggregated per-day/per-model history Claude Code maintains. It covers
///   everything **through ``StatsCache/lastComputedDate``** (typically yesterday).
/// - ``JSONLDeltaScanner`` (1.2.2) sums **today's** `message.usage` live from the
///   per-session JSONL files under `~/.claude/projects/*/`, because the cache does
///   not include the current day until Claude Code recomputes it.
///
/// ## Merge rule (and the double-count guard)
///
/// "Today" is owned exclusively by the live JSONL delta; the cache owns every day
/// strictly **before** today. Concretely:
///
/// 1. Every `dailyModelTokens` entry whose `date` is **not** today becomes a
///    historical ``UsageRecord``.
/// 2. The cache's *today* entry — if one exists — is **dropped**. On a freshly
///    recomputed cache `lastComputedDate` can equal today, in which case the cache
///    already contains a (possibly stale) today total. Keeping both it and the
///    live delta would sum the same usage twice, so the cache's today entry is
///    always discarded in favor of the live scan. This guard holds regardless of
///    whether `lastComputedDate` is before, equal to, or (defensively) after
///    today.
/// 3. Today's per-model totals come solely from ``JSONLDeltaScanner/scanToday()``.
///
/// As a result the DoD holds: the total emitted for today equals the manual sum of
/// today's `message.usage` from the JSONLs — never the cache's copy, never both.
///
/// ## Token-breakdown asymmetry
///
/// The two sources expose different fidelity, and that asymmetry is preserved
/// rather than papered over with fabricated zeros (mirroring the Claude/Codex
/// contract documented on ``UsageRecord``):
///
/// - **Today** (JSONL delta) carries the full four-field breakdown
///   (input/output/cache-read/cache-creation), so today's records are fully
///   populated.
/// - **History** (`dailyModelTokens`) is a *single aggregate integer* per
///   (day, model) — Claude Code does not split the daily number into the four
///   fields (see ``DailyModelTokens``). That aggregate is mapped to
///   `inputTokens`, and `outputTokens` / `cacheReadTokens` / `cacheCreationTokens`
///   are left `nil`. ``UsageRecord/totalTokens`` therefore still reports the
///   correct daily total. (The finer lifetime split in ``StatsCache/modelUsage``
///   is *all-time*, not per-day, so it cannot be apportioned back onto individual
///   historical days and is intentionally not consumed here.)
///
/// ## Privacy
///
/// This type performs **no new file reads** beyond what 1.2.1 and 1.2.2 already
/// do. It never touches `~/.claude/history.jsonl`, `~/.claude/sessions/`,
/// `~/.claude/auth.json`, `message.content`, or any response text — it only
/// reassembles the token counts those readers already produced. See
/// docs/data-sources.md and the privacy thesis in CLAUDE.md.
///
/// ## Cost
///
/// Every emitted record leaves `costUSD == nil`; pricing is applied downstream by
/// `CostCalculator` against `PricingTable` (Epic 1.4). This provider never trusts
/// the cache's own `costUSD` field.
public struct ClaudeUsageProvider: Sendable {
    /// Reader for the historical `stats-cache.json` aggregate (≤ yesterday).
    private let statsCacheReader: StatsCacheReader

    /// Scanner for today's live JSONL token delta.
    private let deltaScanner: JSONLDeltaScanner

    /// Calendar used to derive the local "today" key. Defaults to `.current` so
    /// the user's timezone drives day bucketing; injectable for deterministic
    /// tests.
    private let calendar: Calendar

    /// Clock injection point for "today"; defaults to `Date()`.
    private let now: @Sendable () -> Date

    /// Formats a `Date` into Claude Code's `YYYY-MM-DD` day key. `en_US_POSIX` +
    /// a fixed format keeps formatting independent of the user's locale; the
    /// timezone is taken from `calendar` so the formatted day matches the local
    /// calendar day used for the JSONL midnight cutoff.
    private let dayFormatter: DateFormatter

    /// - Parameters:
    ///   - statsCacheReader: Reader for `~/.claude/stats-cache.json`. Defaults to
    ///     the home-relative reader; inject a fixture-backed reader in tests.
    ///   - deltaScanner: Scanner for today's `~/.claude/projects/*/` JSONL delta.
    ///     Defaults to the home-relative scanner; inject a temp-dir scanner in
    ///     tests.
    ///   - calendar: Calendar for the local-today key. Defaults to
    ///     `Calendar.current`.
    ///   - now: Clock for "today". Injectable for deterministic tests. Defaults
    ///     to `Date()`.
    ///
    /// > Important: When injecting both a `calendar`/`now` here, pass the *same*
    /// > `calendar` and `now` into the supplied `deltaScanner` so the provider's
    /// > "today" key and the scanner's local-midnight cutoff agree.
    public init(
        statsCacheReader: StatsCacheReader = StatsCacheReader(),
        deltaScanner: JSONLDeltaScanner = JSONLDeltaScanner(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.statsCacheReader = statsCacheReader
        self.deltaScanner = deltaScanner
        self.calendar = calendar
        self.now = now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
    }

    /// Produces the merged Claude usage timeline: cache history (every day before
    /// today) plus today's live JSONL delta, deduplicated so today is never summed
    /// twice.
    ///
    /// A missing cache file is treated as "no history yet" (via
    /// ``StatsCacheReader/readOrEmpty()``) rather than an error — a fresh machine
    /// still yields today's delta. A missing projects directory likewise yields no
    /// today records. Either source being empty is fine; both empty yields `[]`.
    ///
    /// Records are returned sorted by `(day, model)` for stable, testable output.
    ///
    /// - Returns: merged `[UsageRecord]` with `provider == .claude` and
    ///   `costUSD == nil`.
    /// - Throws: ``StatsCacheReader/ReadError`` only when the cache file exists but
    ///   is genuinely corrupt/undecodable (the "no cache yet" case is swallowed).
    public func usageRecords() throws -> [UsageRecord] {
        let today = dayFormatter.string(from: now())

        var records: [UsageRecord] = []

        // 1. History: every cache day strictly before today. The cache's today
        //    entry (if present, e.g. lastComputedDate == today) is dropped here —
        //    today is owned by the live delta below.
        let cache = try statsCacheReader.readOrEmpty()
        for daily in cache.dailyModelTokens where daily.date != today {
            for (model, tokens) in daily.tokensByModel {
                records.append(
                    UsageRecord(
                        provider: .claude,
                        model: model,
                        day: daily.date,
                        // Per-day cache numbers are a single aggregate with no
                        // breakdown; map to inputTokens, leave the rest nil.
                        inputTokens: tokens,
                        outputTokens: nil,
                        cacheReadTokens: nil,
                        cacheCreationTokens: nil,
                        costUSD: nil
                    )
                )
            }
        }

        // 2. Today: the live JSONL delta is the single source of truth for the
        //    current day, with the full four-field breakdown.
        let todayTotals = deltaScanner.scanToday()
        for (model, totals) in todayTotals {
            records.append(
                UsageRecord(
                    provider: .claude,
                    model: model,
                    day: today,
                    inputTokens: totals.inputTokens,
                    outputTokens: totals.outputTokens,
                    cacheReadTokens: totals.cacheReadTokens,
                    cacheCreationTokens: totals.cacheCreationTokens,
                    costUSD: nil
                )
            )
        }

        // Stable ordering for deterministic consumers/tests.
        records.sort { lhs, rhs in
            lhs.day == rhs.day ? lhs.model < rhs.model : lhs.day < rhs.day
        }
        return records
    }
}
