import Foundation

/// The set of machines the user has chosen to hide from the combined view and the
/// Devices table's "active fleet", persisted to `UserDefaults` as a JSON array of
/// `machine_id`s (Epic 2.4.4).
///
/// "Hide" is a deliberate, user-driven exclusion — distinct from the automatic
/// staleness in 2.3.4. A user might hide a retired laptop or a shared CI box so it
/// stops inflating the grand total, while keeping its rollup file on disk (hiding
/// never deletes anything — that's what "forget" does). A hidden machine is
/// excluded from the reconciled combined total but still appears in the Devices
/// table, flagged as hidden, so the user can unhide it later.
///
/// Privacy: only the opaque `machine_id` (the SHA-256-derived id from 2.1.1) is
/// stored, under Burnbar's own `xyz.andybowu.Burnbar.*` namespace — never `cwd`,
/// `git_*`, project dir names, or any other identifying path (the privacy thesis).
///
/// Like `MachineRegistry` (2.3.2), this is a small value type holding only its
/// injected `UserDefaults`; its only effect is writing through to the thread-safe
/// store. It is intentionally **not** declared `Sendable`: `UserDefaults` is
/// thread-safe but not `Sendable`-annotated by Apple, and forcing the conformance
/// would require an `@unchecked` escape hatch. Construct a store where you use it.
public struct HiddenMachines {
    /// `UserDefaults` key the hidden-id set is persisted under.
    public static let defaultsKey = "xyz.andybowu.Burnbar.hiddenMachines"

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage for the hidden set (injectable for tests).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// Every hidden `machine_id`, as a set for O(1) membership checks.
    public func hiddenIDs() -> Set<String> {
        guard let stored = defaults.array(forKey: Self.defaultsKey) as? [String] else {
            return []
        }
        return Set(stored)
    }

    /// Whether `machineID` is currently hidden.
    public func isHidden(_ machineID: String) -> Bool {
        hiddenIDs().contains(machineID)
    }

    // MARK: - Mutations

    /// Hide `machineID` — add it to the persisted set. A no-op if already hidden.
    public func hide(_ machineID: String) {
        var ids = hiddenIDs()
        guard ids.insert(machineID).inserted else { return }
        save(ids)
    }

    /// Unhide `machineID` — remove it from the persisted set. A no-op if not hidden.
    public func unhide(_ machineID: String) {
        var ids = hiddenIDs()
        guard ids.remove(machineID) != nil else { return }
        save(ids)
    }

    /// Toggle `machineID`'s hidden state, returning its new state (`true` = now
    /// hidden). Convenience for a single UI control.
    @discardableResult
    public func toggle(_ machineID: String) -> Bool {
        if isHidden(machineID) {
            unhide(machineID)
            return false
        }
        hide(machineID)
        return true
    }

    /// Drop `machineID` from the hidden set entirely. Called when a machine is
    /// "forgotten" (its rollup file deleted) so a stale id never lingers in the
    /// hidden set and silently re-hides a machine that later reappears.
    public func forget(_ machineID: String) {
        unhide(machineID)
    }

    /// Partition `machineIDs` into the visible (not hidden) subset, preserving the
    /// input order. The combined-view caller uses this to exclude hidden machines
    /// from the reconciled total.
    public func visible(from machineIDs: some Sequence<String>) -> [String] {
        let hidden = hiddenIDs()
        return machineIDs.filter { !hidden.contains($0) }
    }

    // MARK: - Persistence

    /// Encode and write the set through to `UserDefaults` (sorted for a stable,
    /// diff-friendly on-disk representation), so a freshly constructed store over
    /// the same defaults sees the change.
    private func save(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.defaultsKey)
    }
}
