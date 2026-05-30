import Foundation

/// Pure, view-agnostic label for the popover's "N Macs syncing" badge (Epic 2.4.2).
///
/// In All-Macs mode the popover shows the combined burn across every machine
/// (wired by 2.4.1) plus a small badge telling the user how many machines are
/// contributing to that total. The count comes from the reconciled data —
/// `ReconciledUsage.byMachine.count`, i.e. exactly the machines whose records were
/// summed into the combined view — so the badge and the summed burn never disagree.
///
/// Rather than scatter the count→string mapping (and its singular/plural handling)
/// inside the SwiftUI view, this enum owns it: the view passes the machine count
/// and renders the resulting literal. That keeps the wording unit-testable without
/// launching the app.
///
/// English-only literals throughout, per the MVP constraint in CLAUDE.md. The
/// expandable per-machine breakdown panel (2.4.3) is intentionally out of scope
/// here — this is only the count + its label.
public enum SyncingBadge {
    /// The badge text for a given machine count, with singular/plural handling.
    ///
    /// - `0` → "No Macs syncing" (the combined view resolved but found no machine
    ///   rollups — e.g. iCloud is empty or unavailable).
    /// - `1` → "1 Mac syncing" (singular).
    /// - `n > 1` → "n Macs syncing" (plural).
    ///
    /// - Parameter machineCount: Number of machines in the reconciled data
    ///   (`ReconciledUsage.byMachine.count`). Negative inputs are clamped to `0`.
    /// - Returns: the exact English string the badge displays.
    public static func text(machineCount: Int) -> String {
        let count = max(0, machineCount)
        switch count {
        case 0: return "No Macs syncing"
        case 1: return "1 Mac syncing"
        default: return "\(count) Macs syncing"
        }
    }
}
