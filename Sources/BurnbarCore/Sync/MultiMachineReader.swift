import Foundation

/// One machine's decoded rollup snapshot: every `UsageRecord` recovered from that
/// machine's `{machine_id}.jsonl` file in the shared iCloud directory.
///
/// This is the per-machine unit the Reconciler (Epic 2.3) consumes — the identity
/// table (2.3.2) labels it and the merge step (2.3.3) unions records across
/// machines. `records` is reconstructed from each `RollupLine` (the only shape
/// `DailyRollupWriter`/2.2.2 writes), so it carries the same hard privacy
/// allowlist: token counts, model, day, cost — never paths, `git_*`, or content.
public struct MachineUsage: Sendable, Equatable {
    /// The machine identity, taken verbatim from the rollup filename stem
    /// (`{machine_id}.jsonl` → `machine_id`).
    public let machineID: String

    /// Every `UsageRecord` decoded from this machine's rollup file, in file
    /// order. A machine that wrote an empty rollup (zero usage) yields `[]`.
    public let records: [UsageRecord]

    public init(machineID: String, records: [UsageRecord]) {
        self.machineID = machineID
        self.records = records
    }

    /// The latest `day` (`YYYY-MM-DD`) across this machine's records, or `nil`
    /// when it has none. Days are zero-padded `YYYY-MM-DD`, so lexicographic max
    /// equals chronological max — no date parsing required.
    public var lastRecordDay: String? {
        records.map(\.day).max()
    }
}

/// Stage one of the reconciler: enumerate every machine's rollup file in the
/// shared iCloud directory and decode each into an in-memory `MachineUsage`
/// snapshot.
///
/// Each machine owns exactly one `{machine_id}.jsonl` file (written by
/// `DailyRollupWriter`, 2.2.2), so reading is a conflict-free union: scan every
/// `*.jsonl`, take the filename stem as the `machine_id`, and decode each line
/// back into a `UsageRecord`.
///
/// Robustness is the contract here — this runs against live iCloud files that may
/// be mid-sync, partially downloaded, or stale. A missing directory yields an
/// empty result; a missing, unreadable, or corrupt file (or an undecodable line
/// within an otherwise-valid file) is logged to stderr and **skipped**, never
/// throwing out the whole read. Partial files contribute their valid lines.
///
/// The shared directory is injected (the caller passes the URL resolved by
/// `ICloudContainer`, 2.2.1), so tests point it at a temp directory.
///
/// `Sendable` and stateless: holds only an immutable directory URL and injected
/// read closures, so it is safe to call from any concurrency domain.
public struct MultiMachineReader: Sendable {
    /// The resolved shared `Burnbar/` directory holding every `{machine_id}.jsonl`.
    private let directory: URL

    /// Injected directory enumeration: returns the file URLs directly under
    /// `directory`, or `nil` when the directory is absent/unreadable. Defaults to
    /// a shallow, non-recursive `FileManager` listing that skips hidden files.
    private let listDirectory: @Sendable (URL) -> [URL]?

    /// Injected per-file read: returns the file's bytes, or `nil` when the file is
    /// missing/unreadable. Defaults to `Data(contentsOf:)`.
    private let readData: @Sendable (URL) -> Data?

    public init(
        directory: URL,
        listDirectory: @escaping @Sendable (URL) -> [URL]? = { directory in
            try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        },
        readData: @escaping @Sendable (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        }
    ) {
        self.directory = directory
        self.listDirectory = listDirectory
        self.readData = readData
    }

    /// Read every machine's rollup file into a typed snapshot list.
    ///
    /// Files are matched by a `.jsonl` extension; the `.tmp` staging files written
    /// by the atomic writer (2.2.3) are ignored. Results are sorted by `machineID`
    /// for deterministic output. A missing/empty directory yields `[]`.
    ///
    /// Never throws: unreadable/corrupt files and undecodable lines are logged and
    /// skipped, so one bad machine file can't sink the whole reconciliation.
    public func readMachines() -> [MachineUsage] {
        guard let entries = listDirectory(directory) else {
            // Missing or unreadable directory → no machines, not an error.
            return []
        }

        let rollupFiles = entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var snapshots: [MachineUsage] = []
        snapshots.reserveCapacity(rollupFiles.count)

        for file in rollupFiles {
            let machineID = file.deletingPathExtension().lastPathComponent

            guard let data = readData(file) else {
                Self.log("skipping unreadable rollup file \(file.lastPathComponent)")
                continue
            }

            let records = decodeRecords(from: data, machineID: machineID)
            snapshots.append(MachineUsage(machineID: machineID, records: records))
        }

        return snapshots
    }

    /// Convenience projection matching the ticket's `[machine_id: [UsageRecord]]`
    /// contract — the input the merge step (2.3.3) consumes.
    public func readAll() -> [String: [UsageRecord]] {
        var map: [String: [UsageRecord]] = [:]
        for snapshot in readMachines() {
            map[snapshot.machineID] = snapshot.records
        }
        return map
    }

    // MARK: - Line decoding

    /// Decode one machine file's bytes into `UsageRecord`s, one JSONL line each.
    ///
    /// Lines are decoded as `RollupLine` (the writer's shape) and lifted back to
    /// `UsageRecord`. Blank lines (e.g. a stray trailing newline) are ignored; a
    /// line that fails to decode is logged and skipped so the surrounding valid
    /// lines still survive.
    private func decodeRecords(from data: Data, machineID: String) -> [UsageRecord] {
        guard let text = String(data: data, encoding: .utf8) else {
            Self.log("rollup file for \(machineID) is not valid UTF-8 — skipping")
            return []
        }

        let decoder = JSONDecoder()
        var records: [UsageRecord] = []

        // `enumerated` gives a 1-based human line number for diagnostics.
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            guard let rollup = try? decoder.decode(RollupLine.self, from: Data(line.utf8)) else {
                Self.log("skipping undecodable line \(index + 1) in \(machineID).jsonl")
                continue
            }

            records.append(Self.usageRecord(from: rollup))
        }

        return records
    }

    /// Lift a `RollupLine` back into a `UsageRecord`. Field-for-field — the rollup
    /// is the persisted projection of a `UsageRecord`, so the costing/asymmetry
    /// nuances (`nil` token categories, `nil` cost) round-trip unchanged.
    private static func usageRecord(from line: RollupLine) -> UsageRecord {
        UsageRecord(
            provider: line.provider,
            model: line.model,
            day: line.date,
            inputTokens: line.inputTokens,
            outputTokens: line.outputTokens,
            cacheReadTokens: line.cacheReadTokens,
            cacheCreationTokens: line.cacheCreationTokens,
            costUSD: line.costUSD
        )
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        // Lightweight stderr logging, matching the reader house style; never
        // throws, never blocks the caller.
        FileHandle.standardError.write(Data("[MultiMachineReader] \(message)\n".utf8))
    }
}
