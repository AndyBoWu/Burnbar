import Foundation

/// Stale-machine detection (2.3.4): flags machines that have gone quiet for longer
/// than `staleThresholdDays`, and a stale-aware merge that drops them from the
/// combined view by default.
///
/// A machine is **stale** when its most-recent activity is more than 30 days
/// before a given `now`. "Most-recent activity" is the machine's `lastSeen` from
/// the `MachineRegistry` (2.3.2) when available, otherwise the latest record `day`
/// the reconciler holds for it — so a machine whose registry entry is missing
/// (temporarily absent file, evicted iCloud cache) is still judged against its own
/// data rather than being silently treated as fresh or dropped.
///
/// Decommissioned / reinstalled / long-offline machines should not silently inflate
/// or skew the combined grand total (Epic 2.4), so they are excluded from the merge
/// by default. The `includeStale` flag is the opt-in that brings them back — bound
/// in the UI (Epic 2.4.4) to the `xyz.andybowu.Burnbar.includeStaleMachines`
/// preference.
///
/// This is **pure logic**: `now` and all data are injected, there is no clock, I/O,
/// or global state. That keeps the boundary (exactly-30 days vs. 31 vs. 29)
/// trivially testable and the type `Sendable`.
public struct StaleMachineDetector: Sendable {
    /// A machine is stale once its most-recent activity is strictly more than this
    /// many days before `now`. Activity exactly `staleThresholdDays` old (to the
    /// second) is still fresh — only *older* than the threshold is stale.
    public static let staleThresholdDays = 30

    /// `UserDefaults` key the "include stale machines" preference is persisted
    /// under. Default (absent key) is `false` — stale machines are hidden until the
    /// user opts in via Settings → Devices (Epic 2.4.4).
    public static let includeStalePreferenceKey = "xyz.andybowu.Burnbar.includeStaleMachines"

    /// The merge used to fold non-stale (or all, when `includeStale`) machines into
    /// the combined view. Injected so the detector composes with the existing
    /// `Reconciler` without owning the fold.
    private let reconciler: Reconciler

    public init(reconciler: Reconciler = Reconciler()) {
        self.reconciler = reconciler
    }

    // MARK: - Threshold

    /// The cutoff instant: activity at or after this is fresh, strictly before it is
    /// stale. Exactly `staleThresholdDays` before `now`.
    private static func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(staleThresholdDays) * 86_400)
    }

    /// Whether a machine whose most-recent activity was at `lastActivity` is stale
    /// relative to `now`.
    ///
    /// Stale ⇔ `lastActivity` is strictly more than `staleThresholdDays` before
    /// `now`. Activity exactly on the boundary (e.g. 30 days ago to the second) is
    /// **fresh**; only older activity is stale.
    public func isStale(lastActivity: Date, now: Date) -> Bool {
        lastActivity < Self.cutoff(now: now)
    }

    // MARK: - Flagging

    /// Classify every machine in `byMachine` as stale or fresh relative to `now`,
    /// returning the set of stale `machine_id`s.
    ///
    /// A machine's most-recent activity is taken from the `registry`'s `lastSeen`
    /// when that machine is known, otherwise from the latest record `day` present in
    /// its own usage (parsed as a `YYYY-MM-DD` local calendar day). A machine with
    /// neither a registry entry nor any dated record cannot be judged stale, so it
    /// is treated as **fresh** (never silently excluded on missing data).
    ///
    /// - Parameters:
    ///   - byMachine: `[machine_id: [UsageRecord]]`, as produced by
    ///     `MultiMachineReader.readAll()` (2.3.1).
    ///   - registry: roster of last-seen timestamps (2.3.2); the authoritative
    ///     activity source when a machine is present.
    ///   - now: injected "current" instant the threshold is measured against.
    /// - Returns: the `machine_id`s judged stale.
    public func staleMachineIDs(
        in byMachine: [String: [UsageRecord]],
        registry: MachineRegistry,
        now: Date
    ) -> Set<String> {
        var stale: Set<String> = []
        for machineID in byMachine.keys {
            guard let lastActivity = lastActivity(
                machineID: machineID,
                records: byMachine[machineID] ?? [],
                registry: registry
            ) else {
                // No registry entry and no dated record → cannot judge → fresh.
                continue
            }
            if isStale(lastActivity: lastActivity, now: now) {
                stale.insert(machineID)
            }
        }
        return stale
    }

    // MARK: - Stale-aware merge

    /// Fold per-machine usage into the combined daily view, excluding stale machines
    /// by default.
    ///
    /// Stale machines are dropped from **both** the combined fold and the passed-
    /// through `byMachine` breakdown, so the Combined-view total and its drilldown
    /// agree on which machines contributed. Setting `includeStale: true` skips the
    /// filter entirely — the result is then identical to `Reconciler.merge`.
    ///
    /// - Parameters:
    ///   - byMachine: `[machine_id: [UsageRecord]]` to reconcile.
    ///   - registry: last-seen roster (2.3.2) used to judge staleness.
    ///   - now: injected current instant.
    ///   - includeStale: when `false` (default), stale machines are excluded; when
    ///     `true`, every machine is merged regardless of staleness.
    /// - Returns: the reconciled view over the retained machines.
    public func merge(
        _ byMachine: [String: [UsageRecord]],
        registry: MachineRegistry,
        now: Date,
        includeStale: Bool = false
    ) -> ReconciledUsage {
        guard !includeStale else {
            return reconciler.merge(byMachine)
        }
        let stale = staleMachineIDs(in: byMachine, registry: registry, now: now)
        guard !stale.isEmpty else {
            return reconciler.merge(byMachine)
        }
        let retained = byMachine.filter { !stale.contains($0.key) }
        return reconciler.merge(retained)
    }

    // MARK: - Activity resolution

    /// The most-recent activity instant for one machine: the registry `lastSeen`
    /// when the machine is known, otherwise the latest `YYYY-MM-DD` record `day`
    /// parsed at the start of that UTC day. `nil` when neither is available.
    private func lastActivity(
        machineID: String,
        records: [UsageRecord],
        registry: MachineRegistry
    ) -> Date? {
        if let entry = registry.machine(id: machineID) {
            return entry.lastSeen
        }
        return latestRecordDay(in: records)
    }

    /// Parse the latest `day` across `records` into a `Date` at 00:00:00 UTC. Days
    /// are zero-padded `YYYY-MM-DD`, so the lexicographic max is the chronological
    /// max. `nil` when there are no records or none parse.
    private func latestRecordDay(in records: [UsageRecord]) -> Date? {
        guard let latest = records.map(\.day).max() else { return nil }
        return Self.dayFormatter.date(from: latest)
    }

    /// Fixed UTC `YYYY-MM-DD` parser. UTC + POSIX locale keep parsing independent of
    /// the host's time zone and locale, matching how `day` strings are produced.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// The persisted "include stale machines" preference (default `false`), backing the
/// Settings → Devices toggle (Epic 2.4.4) and the `includeStale` argument to
/// `StaleMachineDetector.merge`.
///
/// A thin, injectable wrapper over `UserDefaults` so the toggle and the reconcile
/// path read the same key without duplicating the string. Like `MachineRegistry`,
/// it is intentionally **not** `Sendable`: `UserDefaults` is thread-safe but not
/// `Sendable`-annotated, so construct one where you use it.
public struct IncludeStaleMachinesPreference {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether stale machines should be included in the combined view. Absent key
    /// (never set) reads as `false` — stale machines hidden until the user opts in.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: StaleMachineDetector.includeStalePreferenceKey) }
        nonmutating set { defaults.set(newValue, forKey: StaleMachineDetector.includeStalePreferenceKey) }
    }
}
