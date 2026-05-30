import Foundation

// =============================================================================
// SyncWriteCoordinator (2.2.4) — the testable core of the iCloud write
// scheduler. Performs one rollup write attempt and owns the bookkeeping the
// Definition of Done checks: persist `last-write-at` only on a successful write,
// skip (without crashing or touching the timestamp) when iCloud is unavailable,
// and never let two write attempts overlap.
//
// The app-side `SyncWriteController` (Burnbar target) owns the `Timer`,
// `NSApplication.willTerminateNotification`, and `NSWorkspace.didWakeNotification`
// triggers and simply asks this coordinator to `write()` on each. All blocking
// I/O — resolving the iCloud directory (`ICloudContainer.resolve()` blocks),
// loading + pricing usage, and the atomic file write — is injected as closures,
// so the AppKit-free logic is unit-testable with fakes (no real iCloud account,
// no real providers) and runs off the main thread in production.
//
// Concurrency: an `actor`, so its mutable in-flight state is data-race-free and a
// timer tick that arrives while a wake- or quit-triggered write is still running
// is dropped (`.skippedInFlight`) rather than racing it. This is the overlap
// guard the ticket requires.
// =============================================================================

/// Reason a single write attempt did not produce a fresh rollup. Returned (not
/// thrown) so the caller can log/telemeter without treating a benign skip as an
/// error.
public enum SyncWriteSkip: Equatable, Sendable {
    /// iCloud Drive is disabled / signed out (`ICloudLocation.unavailable`). The
    /// carried string is the human-readable reason from `ICloudContainer`.
    case iCloudUnavailable(reason: String)
    /// Another write was already running; this attempt was coalesced away by the
    /// overlap guard.
    case alreadyInFlight
}

/// Outcome of one ``SyncWriteCoordinator/write()`` attempt.
public enum SyncWriteOutcome: Equatable, Sendable {
    /// A rollup file was written and `last-write-at` advanced to this instant.
    case wrote(at: Date)
    /// No write happened; `last-write-at` is unchanged. Carries the reason.
    case skipped(SyncWriteSkip)
    /// Resolving/loading/writing threw. `last-write-at` is unchanged. Carries a
    /// human-readable description for logging.
    case failed(reason: String)
}

/// Persists and reads the `last-write-at` timestamp. Abstracted so tests can
/// observe the stored value without a real `UserDefaults` domain.
public protocol LastWriteStore: Sendable {
    /// The instant of the last successful write, or `nil` if none recorded.
    func lastWriteAt() -> Date?
    /// Record `date` as the instant of the latest successful write.
    func setLastWriteAt(_ date: Date)
}

/// `UserDefaults`-backed ``LastWriteStore`` writing the standard ``key`` slot.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but is not
/// formally `Sendable`. The store holds only the (immutable) defaults reference
/// and key, and all access goes through `UserDefaults`' own synchronized API, so
/// sharing it across the coordinator's actor boundary is safe.
public struct UserDefaultsLastWriteStore: LastWriteStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = SyncWriteSchedule.lastWriteAtKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func lastWriteAt() -> Date? {
        // `object(forKey:)` returns nil (not the 1970 epoch) when never set.
        defaults.object(forKey: key) as? Date
    }

    public func setLastWriteAt(_ date: Date) {
        defaults.set(date, forKey: key)
    }
}

/// Performs one iCloud rollup write attempt with full bookkeeping, serializing
/// concurrent attempts. See the file banner for the design rationale.
public actor SyncWriteCoordinator {
    /// Resolve the destination directory. Blocks (ubiquity lookup), so it is run
    /// inside the actor's isolated, off-main context. In production this wraps
    /// `ICloudContainer().resolve()`.
    private let resolveLocation: @Sendable () -> ICloudLocation
    /// Load this machine's already-priced usage across *all* days (not just
    /// today) — the rollup is the full per-machine history. In production this
    /// runs the same Claude + Codex providers `UsageStore` uses, priced via
    /// `CostCalculator`. `async` so the actor *suspends* here: the overlap guard
    /// (`isWriting`) is what prevents a trigger that arrives during this
    /// suspension from starting a second concurrent write.
    private let loadRecords: @Sendable () async throws -> [UsageRecord]
    /// This machine's stable id (`MachineIdentity.current()`), used as the file
    /// name. Captured as a closure so tests can pin it.
    private let machineID: @Sendable () -> String
    /// Write the records to `{machineID}.jsonl` in `directory`. In production
    /// this is `DailyRollupWriter(directory:).write(records:machineID:)`.
    private let writeRollup: @Sendable (_ records: [UsageRecord], _ directory: URL, _ machineID: String) throws -> Void
    /// Timestamp persistence (the DoD's `last-write-at`).
    private let store: LastWriteStore
    /// Injected clock so tests assert the exact recorded instant.
    private let now: @Sendable () -> Date

    /// Overlap guard: `true` while a `write()` body is running, so a concurrent
    /// trigger is coalesced to ``SyncWriteSkip/alreadyInFlight``.
    private var isWriting = false

    public init(
        resolveLocation: @escaping @Sendable () -> ICloudLocation,
        loadRecords: @escaping @Sendable () async throws -> [UsageRecord],
        machineID: @escaping @Sendable () -> String,
        writeRollup: @escaping @Sendable (_ records: [UsageRecord], _ directory: URL, _ machineID: String) throws
            -> Void,
        store: LastWriteStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.resolveLocation = resolveLocation
        self.loadRecords = loadRecords
        self.machineID = machineID
        self.writeRollup = writeRollup
        self.store = store
        self.now = now
    }

    /// The currently recorded `last-write-at`, or `nil` if none. Convenience for
    /// callers/tests that want to observe the timestamp through the coordinator.
    public func lastWriteAt() -> Date? {
        store.lastWriteAt()
    }

    /// Attempt one rollup write.
    ///
    /// Steps, in order, all inside the actor (so they cannot interleave with
    /// another `write()`):
    ///   1. If a write is already in flight, return ``SyncWriteSkip/alreadyInFlight``.
    ///   2. Resolve the iCloud directory. If `.unavailable`, return
    ///      ``SyncWriteSkip/iCloudUnavailable`` — `last-write-at` is left
    ///      untouched and nothing is written (no partial state, no crash).
    ///   3. Load + write the rollup. On success, persist `now()` as
    ///      `last-write-at` and return ``SyncWriteOutcome/wrote(at:)``.
    ///   4. Any thrown error becomes ``SyncWriteOutcome/failed`` with the
    ///      timestamp unchanged.
    ///
    /// - Returns: the outcome; never throws (errors are returned as `.failed`).
    @discardableResult
    public func write() async -> SyncWriteOutcome {
        await writeOnce()
    }

    /// Manual-trigger entry point for the "Force resync" action (2.5.3).
    ///
    /// Identical to ``write()`` — one immediate rollup write with the same overlap
    /// guard — but named so the call site reads as a user-initiated resync rather
    /// than a scheduled tick. Lets the Settings → Devices button force a fresh
    /// `{machine_id}.jsonl` on demand without waiting for the next timer fire,
    /// coalescing cleanly (``SyncWriteSkip/alreadyInFlight``) if a scheduled write
    /// happens to be mid-flight.
    ///
    /// - Returns: the outcome; never throws (errors are returned as `.failed`).
    @discardableResult
    public func forceWrite() async -> SyncWriteOutcome {
        await writeOnce()
    }

    /// Shared body for ``write()`` / ``forceWrite()``: see ``write()`` for the
    /// step-by-step contract.
    private func writeOnce() async -> SyncWriteOutcome {
        guard !isWriting else { return .skipped(.alreadyInFlight) }
        isWriting = true
        defer { isWriting = false }

        let location = resolveLocation()
        guard let directory = location.url else {
            let reason: String = if case let .unavailable(unavailableReason) = location {
                unavailableReason
            } else {
                "iCloud unavailable."
            }
            return .skipped(.iCloudUnavailable(reason: reason))
        }

        do {
            let records = try await loadRecords()
            let id = machineID()
            try writeRollup(records, directory, id)
            let timestamp = now()
            store.setLastWriteAt(timestamp)
            return .wrote(at: timestamp)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
