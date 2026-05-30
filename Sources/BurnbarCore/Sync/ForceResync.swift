import Foundation

// =============================================================================
// ForceResync (2.5.3) — the testable core of the manual "Force resync" action.
//
// When the combined cross-device view looks stale (or the user has just fixed
// iCloud), the Settings → Devices "Force resync" button performs an immediate
// rollup WRITE of this machine's `{machine_id}.jsonl`, then a READ across every
// machine's file, without waiting for the next scheduled write. This type owns
// that write-then-read sequence and the structured `SyncLog` bookkeeping the
// Definition of Done checks; the SwiftUI button only kicks it off and refreshes
// the table afterwards.
//
// The two side effects are injected as closures (the app wires the real
// `SyncWriteCoordinator.forceWrite()` and `MultiMachineReader.readMachines()`),
// so the ordering + logging are unit-testable with fakes — no real iCloud, no
// real providers. All blocking work runs inside the injected closures (the
// coordinator is an `actor`; the read hops off-main in the UI), so this `Sendable`
// value type never pins itself to the main thread.
//
// PRIVACY (load-bearing): the log line records only the write status, the
// machines-read count, the duration, and any error code — never user content or a
// filesystem path outside the Burnbar sync dir. The structured detail is composed
// here from non-identifying fields only.
// =============================================================================

/// Outcome of one ``ForceResync/run()``: enough for the UI to react and for the
/// log line to be reconstructed/asserted in tests. `Sendable` so it crosses the
/// resync's concurrency boundary back to the main actor.
public struct ForceResyncResult: Sendable, Equatable {
    /// The write attempt's outcome (wrote / skipped / failed).
    public let writeOutcome: SyncWriteOutcome
    /// How many machine rollup files were read after the write.
    public let machinesRead: Int
    /// Wall-clock duration of the whole resync, in milliseconds.
    public let durationMillis: Int

    public init(writeOutcome: SyncWriteOutcome, machinesRead: Int, durationMillis: Int) {
        self.writeOutcome = writeOutcome
        self.machinesRead = machinesRead
        self.durationMillis = durationMillis
    }
}

/// Drives the manual resync: WRITE this machine's rollup, then READ every
/// machine's file, logging a single structured line. See the file banner for the
/// design rationale.
///
/// `Sendable` and stateless apart from its injected collaborators, so it is safe
/// to call from any concurrency domain (the UI calls it from a background `Task`).
public struct ForceResync: Sendable {
    /// Force one immediate rollup write (the manual-trigger entry point on
    /// `SyncWriteCoordinator`). Runs first.
    private let write: @Sendable () async -> SyncWriteOutcome
    /// Read every machine's rollup file (`MultiMachineReader.readMachines()`).
    /// Runs second — strictly after `write` returns — so the re-read reflects the
    /// freshly written file. Returns the machines-read count.
    private let readMachineCount: @Sendable () async -> Int
    /// Structured diagnostic log (2.5.3).
    private let log: SyncLog
    /// Injected monotonic-ish clock for the duration measurement. Defaults to the
    /// system clock; tests inject a stepping clock to assert a deterministic
    /// duration.
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - write: the manual write trigger (`coordinator.forceWrite()`).
    ///   - readMachineCount: re-read across all machines, returning the count
    ///     (e.g. `MultiMachineReader(...).readMachines().count`).
    ///   - log: the structured sync log.
    ///   - now: clock for the duration measurement (default: `Date()`).
    public init(
        write: @escaping @Sendable () async -> SyncWriteOutcome,
        readMachineCount: @escaping @Sendable () async -> Int,
        log: SyncLog = SyncLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.write = write
        self.readMachineCount = readMachineCount
        self.log = log
        self.now = now
    }

    /// Run the resync: log start, WRITE, then READ, then log the result.
    ///
    /// Ordering is the contract (and a DoD test): `write` is awaited to completion
    /// before `readMachineCount` is called, so the re-read sees the just-written
    /// file. Returns a ``ForceResyncResult`` the UI uses to refresh and that
    /// mirrors the logged line.
    @discardableResult
    public func run() async -> ForceResyncResult {
        let start = now()
        log.append("force-resync start")

        let writeOutcome = await write()
        let machinesRead = await readMachineCount()

        let durationMillis = Self.millis(from: start, to: now())
        let result = ForceResyncResult(
            writeOutcome: writeOutcome,
            machinesRead: machinesRead,
            durationMillis: durationMillis
        )

        log.append(Self.resultDetail(for: result))
        return result
    }

    // MARK: - Log formatting

    /// The privacy-safe structured result line, e.g.
    /// `"force-resync done write=wrote machines=3 duration_ms=420"` or, on
    /// failure, `"force-resync done write=failed machines=3 duration_ms=420 error=\"…\""`.
    /// Only status / count / timing / error code — never content or paths.
    static func resultDetail(for result: ForceResyncResult) -> String {
        var detail = "force-resync done"
            + " write=\(writeStatus(result.writeOutcome))"
            + " machines=\(result.machinesRead)"
            + " duration_ms=\(result.durationMillis)"
        if let error = errorDetail(result.writeOutcome) {
            detail += " error=\"\(error)\""
        }
        return detail
    }

    /// A short, stable token for the write outcome's category — the loggable
    /// "status" the DoD references.
    private static func writeStatus(_ outcome: SyncWriteOutcome) -> String {
        switch outcome {
        case .wrote: "wrote"
        case let .skipped(skip):
            switch skip {
            case .iCloudUnavailable: "skipped_icloud_unavailable"
            case .alreadyInFlight: "skipped_in_flight"
            }
        case .failed: "failed"
        }
    }

    /// The human-readable reason for a non-success outcome, sanitized so it never
    /// embeds a quote or newline that could break the structured line. `nil` for a
    /// successful write.
    private static func errorDetail(_ outcome: SyncWriteOutcome) -> String? {
        let raw: String? = switch outcome {
        case .wrote: nil
        case let .skipped(.iCloudUnavailable(reason)): reason
        case .skipped(.alreadyInFlight): nil
        case let .failed(reason): reason
        }
        guard let raw else { return nil }
        return raw
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Non-negative whole-millisecond elapsed time between two instants.
    private static func millis(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
