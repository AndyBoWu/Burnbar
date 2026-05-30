import Foundation

// Pure, view-agnostic model + storage key for the popover's "This Mac | All Macs"
// segmented control (Epic 2.4.1). Living in `BurnbarCore` keeps the case set,
// labels, default, and the `UserDefaults` round-trip unit-testable without
// launching the app — the SwiftUI `PopoverContentView` binds to it via
// `@AppStorage` and `UsageStore` reads the same key to pick its data source.
//
// English-only literals throughout (no String Catalog / `String(localized:)`),
// per the MVP constraint in CLAUDE.md.

/// Which data source feeds the popover's tiles and burn bars.
///
/// `.thisMac` is the original local-only view (this machine's `ClaudeUsageProvider`
/// + `CodexThreadsReader` output). `.allMacs` is the cross-device combined view:
/// every machine's iCloud rollup reconciled into one daily total (Epic 2.3's
/// `Reconciler`). The user flips between them with a segmented control and the
/// choice persists across relaunch.
///
/// The raw values are **stable storage tokens** — never rename them or a user's
/// persisted choice would silently reset on upgrade.
public enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    /// Local-only: just this machine's usage (the pre-2.4 behavior).
    case thisMac
    /// Combined: every machine's usage, reconciled across devices.
    case allMacs

    public var id: String { rawValue }

    /// The `UserDefaults` key the popover's choice persists under. Centralized
    /// here (rather than as a bare string literal in the view) so `PopoverContentView`'s
    /// `@AppStorage` and any `UserDefaults` read agree on the same slot.
    public static let storageKey = "popover.viewMode"

    /// The default before the user touches the control: this machine only, so a
    /// fresh install behaves exactly as it did pre-2.4 (no iCloud read until the
    /// user opts into the combined view).
    public static let `default`: ViewMode = .thisMac

    /// English label shown on the segmented control.
    public var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .allMacs: return "All Macs"
        }
    }

    /// Decode a stored raw value, falling back to ``default`` for an absent or
    /// unrecognized token (e.g. a value written by a newer build).
    public static func fromStorage(_ raw: String?) -> ViewMode {
        guard let raw, let mode = ViewMode(rawValue: raw) else { return .default }
        return mode
    }
}
