import Foundation

/// One known machine's durable identity: its opaque `machine_id`, a
/// human-readable `label`, and when it was `lastSeen` in the shared rollup set.
///
/// Privacy: only the `machine_id` (the SHA-256-derived id from 2.1.1) and a
/// user-supplied / default label are stored — never `cwd`, `git_*`, project dir
/// names, or any other identifying path (consistent with the privacy thesis).
public struct MachineIdentityEntry: Codable, Equatable, Sendable {
    /// The opaque machine id (`{machine_id}.jsonl` filename stem).
    public let id: String

    /// Human-readable name shown in the Devices UI. Defaults to the system
    /// computer name for the local machine, otherwise the id itself; a user
    /// rename overrides it and is preserved across re-sightings.
    public var label: String

    /// When this machine was last surfaced by the multi-machine reader — the
    /// latest record day (or read time) at the time of `upsert`. Drives stale
    /// detection (2.3.4).
    public var lastSeen: Date

    public init(id: String, label: String, lastSeen: Date) {
        self.id = id
        self.label = label
        self.lastSeen = lastSeen
    }
}

/// Durable registry of every machine the reconciler has ever seen, persisted to
/// `UserDefaults` as a Codable `[machine_id: MachineIdentityEntry]` table.
///
/// The reconciler reads whichever `{machine_id}.jsonl` files happen to be present
/// on a given sync, but the Devices UI (Epic 2.4) and stale detection (2.3.4)
/// need a *stable* roster that survives a machine's file being temporarily
/// absent (mid-sync, offline, evicted from local iCloud cache). This registry is
/// that roster: machines are auto-added on first sighting and never silently
/// dropped.
///
/// Rename safety is the load-bearing invariant: `upsert` only ever advances
/// `lastSeen` for a known machine — it never rewrites the `label`. So a user
/// rename ("Work Laptop") is never clobbered the next time the reader re-surfaces
/// that machine with its default label. Renames go exclusively through `rename`.
///
/// Both the storage and the default-label source are injected so every branch is
/// unit-testable without touching the host's real defaults or computer name.
///
/// Like `MachineLabel` (2.1.2), this is a small value type holding only its
/// injected dependencies; its only effect is writing through to the thread-safe
/// `UserDefaults`. It is intentionally **not** declared `Sendable`: `UserDefaults`
/// is thread-safe but not `Sendable`-annotated by Apple, and forcing the
/// conformance would require an `@unchecked` escape hatch. Construct a registry
/// where you use it.
public struct MachineRegistry {
    /// `UserDefaults` key the machine table is persisted under.
    public static let defaultsKey = "xyz.andybowu.Burnbar.machines"

    private let defaults: UserDefaults
    private let defaultLabel: (String) -> String

    /// - Parameters:
    ///   - defaults: Storage for the machine table (injectable for tests).
    ///   - defaultLabel: Produces the default label for a newly seen `machine_id`
    ///     (injectable for tests). Defaults to the id verbatim; the local
    ///     machine's friendly name comes from `MachineLabel` (2.1.2), which the
    ///     caller can route in via this closure.
    public init(
        defaults: UserDefaults = .standard,
        defaultLabel: @escaping (String) -> String = { $0 }
    ) {
        self.defaults = defaults
        self.defaultLabel = defaultLabel
    }

    // MARK: - Reads

    /// Look up one machine by id, or `nil` when it has never been seen.
    public func machine(id: String) -> MachineIdentityEntry? {
        load()[id]
    }

    /// Every known machine, sorted by `id` for deterministic output (the Devices
    /// UI applies its own display ordering on top).
    public func all() -> [MachineIdentityEntry] {
        load().values.sorted { $0.id < $1.id }
    }

    // MARK: - Mutations

    /// Record a sighting of `machineID`.
    ///
    /// - New machine: inserted with `defaultLabel(machineID)` and the given
    ///   `lastSeen`.
    /// - Known machine: only `lastSeen` advances; the existing (possibly
    ///   user-renamed) `label` is preserved untouched.
    ///
    /// `lastSeen` is taken as authoritative — the caller passes the latest record
    /// day or the read time — so it is written even if it is older than the stored
    /// value. (The reconciler always feeds a monotonically forward value.)
    public func upsert(machineID: String, lastSeen: Date) {
        var table = load()
        if var existing = table[machineID] {
            existing.lastSeen = lastSeen
            table[machineID] = existing
        } else {
            table[machineID] = MachineIdentityEntry(
                id: machineID,
                label: defaultLabel(machineID),
                lastSeen: lastSeen
            )
        }
        save(table)
    }

    /// Rename a known machine. No-op for an unknown id — labels are only ever
    /// created through `upsert` (first sighting), so there is nothing to rename
    /// for a machine that has never been seen.
    public func rename(machineID: String, to newLabel: String) {
        var table = load()
        guard var existing = table[machineID] else { return }
        existing.label = newLabel
        table[machineID] = existing
        save(table)
    }

    // MARK: - Persistence

    /// Decode the table from `UserDefaults`. A missing key, non-`Data` value, or
    /// undecodable blob yields an empty table rather than throwing — the registry
    /// always presents a usable roster.
    private func load() -> [String: MachineIdentityEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let table = try? JSONDecoder().decode([String: MachineIdentityEntry].self, from: data)
        else {
            return [:]
        }
        return table
    }

    /// Encode and write the table through to `UserDefaults`, so a freshly
    /// constructed registry over the same defaults sees the change.
    private func save(_ table: [String: MachineIdentityEntry]) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
