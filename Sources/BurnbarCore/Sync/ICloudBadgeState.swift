import Foundation

/// Pure, UI-agnostic model for the menu bar "iCloud disabled" warning badge
/// (2.5.1). `MenuBarController` resolves an ``ICloudLocation`` off the main
/// thread, derives this state, and applies it to the `NSStatusItem` button —
/// keeping the decision (and its English-only copy) testable without AppKit.
public enum ICloudBadgeState: Equatable, Sendable {
    /// iCloud Drive is reachable; show the plain `flame.fill` icon with no
    /// warning tooltip.
    case ok
    /// iCloud Drive is disabled or signed out; overlay a warning glyph and set
    /// the explanatory tooltip so the user knows cross-device sync has stopped.
    case warning

    /// Derive the badge state from a resolved iCloud location. `.unavailable`
    /// (and only `.unavailable`) raises the warning; `.container`/`.fallback`
    /// both mean sync can run.
    public init(location: ICloudLocation) {
        self = location.isAvailable ? .ok : .warning
    }

    /// `true` when the warning glyph + tooltip should be shown.
    public var showsWarning: Bool { self == .warning }

    /// The status-item button tooltip while disabled. `nil` when OK so the
    /// caller restores the default Burnbar tooltip / cost title.
    public var tooltip: String? {
        switch self {
        case .ok: return nil
        case .warning: return "iCloud Drive disabled — sync off"
        }
    }

    /// VoiceOver description for the composited warning icon; `nil` when OK so
    /// the plain "Burnbar" flame description is kept.
    public var accessibilityDescription: String? {
        switch self {
        case .ok: return nil
        case .warning: return "Burnbar — iCloud Drive disabled, sync off"
        }
    }
}
