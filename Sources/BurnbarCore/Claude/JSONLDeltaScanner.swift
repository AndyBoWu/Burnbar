import Foundation

/// Per-model token totals accumulated by ``JSONLDeltaScanner``.
///
/// Mirrors the four-field breakdown Claude reports in `message.usage`. Kept as a
/// standalone value type (rather than a full ``UsageRecord``) because the scanner
/// only owns the *today-delta* half of the Claude pipeline; merging with the
/// stats-cache history and minting `UsageRecord`s happens later in
/// `ClaudeUsageProvider` (Epic 1.2.4).
public struct TokenTotals: Sendable, Equatable {
    /// Sum of `message.usage.input_tokens` for the model.
    public var inputTokens: Int
    /// Sum of `message.usage.output_tokens` for the model.
    public var outputTokens: Int
    /// Sum of `message.usage.cache_read_input_tokens` for the model.
    public var cacheReadTokens: Int
    /// Sum of `message.usage.cache_creation_input_tokens` for the model.
    public var cacheCreationTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    /// Sum of all four token fields.
    public var total: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Folds another line's usage into the running total.
    fileprivate mutating func add(_ usage: JSONLDeltaScanner.Usage) {
        inputTokens += usage.input_tokens ?? 0
        outputTokens += usage.output_tokens ?? 0
        cacheReadTokens += usage.cache_read_input_tokens ?? 0
        cacheCreationTokens += usage.cache_creation_input_tokens ?? 0
    }
}

/// Scans today's Claude Code session logs for live token usage.
///
/// The Claude stats cache (`~/.claude/stats-cache.json`, read by
/// `StatsCacheReader`) only covers history through its `lastComputedDate`
/// (yesterday), so *today's* burn must be read live from the per-session JSONL
/// logs that Claude Code appends to as you work. This scanner is the
/// today-delta half of the Claude parser (Epic 1.2): it enumerates
/// `~/.claude/projects/*/<session>.jsonl` files modified since local midnight,
/// stream-parses each line, keeps only `type == "assistant"` lines, and sums
/// `message.usage` token counts grouped by `message.model`.
///
/// ## Privacy
///
/// This scanner deliberately reads **only** `type`, `timestamp`,
/// `message.model`, and `message.usage` token counts. It never decodes
/// `message.content` or any `text`/response field, and never touches
/// `~/.claude/history.jsonl`, `~/.claude/sessions/`, or `~/.claude/auth.json`.
/// The encoded-cwd project directory names are used only to locate files; they
/// are never surfaced or uploaded by this type. See docs/data-sources.md and the
/// privacy thesis in CLAUDE.md.
///
/// ## Robustness
///
/// Claude Code may be appending to a file while it is scanned, so individual
/// lines can be partially written or otherwise malformed. The scanner logs and
/// skips such lines (and unreadable files) rather than throwing — a live tail
/// must never crash the menu-bar agent.
public struct JSONLDeltaScanner: Sendable {
    /// Root projects directory, default `~/.claude/projects`.
    private let projectsDirectory: URL

    /// Calendar used to compute "start of today" in the local timezone.
    private let calendar: Calendar

    /// Clock injection point for tests; defaults to `Date()`.
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - projectsDirectory: Root holding `*/<session>.jsonl`. Defaults to
    ///     `~/.claude/projects`.
    ///   - calendar: Calendar for the local-midnight cutoff. Defaults to
    ///     `Calendar.current`.
    ///   - now: Clock for "today". Injectable for deterministic tests.
    public init(
        projectsDirectory: URL? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectsDirectory =
            projectsDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        self.calendar = calendar
        self.now = now
    }

    /// Sums today's `message.usage` token counts grouped by `message.model`.
    ///
    /// Enumerates every `*.jsonl` under `projectsDirectory/*/` whose content
    /// modification date is at or after local midnight today, stream-parses each,
    /// and aggregates the usage of `type == "assistant"` lines per model.
    ///
    /// - Returns: `[model: TokenTotals]` for today. Empty if nothing matched.
    public func scanToday() -> [String: TokenTotals] {
        let startOfToday = calendar.startOfDay(for: now())
        var totals: [String: TokenTotals] = [:]

        for file in todaysJSONLFiles(modifiedOnOrAfter: startOfToday) {
            accumulate(file: file, into: &totals)
        }

        return totals
    }

    // MARK: - File enumeration

    /// Collects `*.jsonl` files under `projectsDirectory/*/` whose
    /// `contentModificationDate` is `>= cutoff`.
    ///
    /// Using mtime is a cheap pre-filter: a file untouched today cannot contain
    /// today's lines, so we skip parsing it entirely. (We still date-filter at the
    /// directory level only — per-line timestamp filtering is intentionally *not*
    /// done here; the per-day merge in Epic 1.2.4 owns final bucketing. mtime is a
    /// sufficient and conservative gate for "could contain today's usage".)
    private func todaysJSONLFiles(modifiedOnOrAfter cutoff: Date) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey, .isRegularFileKey
        ]

        guard
            let enumerator = fileManager.enumerator(
                at: projectsDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    Self.log("Skipping unreadable path \(url.lastPathComponent): \(error.localizedDescription)")
                    return true
                }
            )
        else {
            // Missing projects dir (e.g. Claude Code never run) is not an error.
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard
                let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { continue }
            if modified >= cutoff {
                files.append(url)
            }
        }
        return files
    }

    // MARK: - Line parsing

    /// Stream-parses one file line-by-line and folds assistant usage into `totals`.
    ///
    /// Reads incrementally so a multi-megabyte session log is never fully
    /// materialized in memory.
    private func accumulate(file: URL, into totals: inout [String: TokenTotals]) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            Self.log("Could not open \(file.lastPathComponent) for reading; skipping")
            return
        }
        defer { try? handle.close() }

        let decoder = JSONDecoder()

        for line in LineSequence(handle: handle) {
            guard !line.isEmpty else { continue }
            guard
                let object = try? decoder.decode(AssistantLine.self, from: line)
            else {
                // Partial/garbled line (Claude may be mid-append) — skip silently
                // at debug volume; counts are eventually consistent on next scan.
                continue
            }
            guard object.type == "assistant",
                  let message = object.message,
                  let usage = message.usage
            else { continue }

            let model = message.model ?? "unknown"
            totals[model, default: TokenTotals()].add(usage)
        }
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        // Lightweight stderr logging; never throws, never blocks the UI.
        FileHandle.standardError.write(Data("[JSONLDeltaScanner] \(message)\n".utf8))
    }

    // MARK: - Codable line model (token counts only — never content)

    /// Minimal decode of a JSONL line.
    ///
    /// Declares **only** the fields Burnbar is allowed to read. Crucially it does
    /// not declare `message.content`/`text`, so even a hostile or malformed line
    /// cannot smuggle response text into memory through this decoder.
    struct AssistantLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    struct Message: Decodable {
        let model: String?
        let usage: Usage?
        // Note: `content` is intentionally absent.
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        // Note: `server_tool_use`, `iterations`, etc. intentionally absent.
    }
}

// MARK: - Streaming line reader

/// Yields one `Data` per newline-delimited line from a `FileHandle`, reading in
/// bounded chunks so whole files are never loaded into memory at once.
private struct LineSequence: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private let chunkSize: Int
    // Plain byte buffer with an integer cursor. Avoids `Data`'s non-zero
    // `startIndex` slicing pitfalls (a memory-mapped `Data(contentsOf:)` does
    // not re-base `startIndex` after `removeSubrange`, which silently corrupts
    // range-based slices).
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var atEOF = false

    init(handle: FileHandle, chunkSize: Int = 64 * 1024) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    private static let newline = UInt8(ascii: "\n")

    mutating func next() -> Data? {
        while true {
            if let relativeIndex = buffer[cursor...].firstIndex(of: Self.newline) {
                let line = Data(buffer[cursor ..< relativeIndex])
                cursor = relativeIndex + 1
                compactIfNeeded()
                return line
            }
            if atEOF {
                guard cursor < buffer.count else { return nil }
                let line = Data(buffer[cursor...])
                cursor = buffer.count
                return line
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                atEOF = true
            } else {
                buffer.append(contentsOf: chunk)
            }
        }
    }

    /// Drops already-consumed bytes once the cursor has advanced far enough,
    /// keeping the working buffer bounded for very large files.
    private mutating func compactIfNeeded() {
        guard cursor >= chunkSize else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }
}
