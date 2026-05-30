import Foundation

/// The tabs of the Settings window (Epic 1.5.5; `devices` added in 2.1.3).
///
/// This is the pure, view-agnostic model of the tab strip: stable identity,
/// English titles, and SF Symbol names. Keeping it in `BurnbarCore` (rather than
/// hardcoding literals in the SwiftUI view) makes the labels unit-testable and
/// gives 1.5.6 / the popover's "Open Settings" action a stable case to deep-link.
///
/// Scaffold scope: identity + labels only. The actual controls (theme, refresh
/// rate, provider toggles, the Devices this-Mac row, links) are added in 1.5.6 /
/// 2.1.3.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case providers
    case devices
    case about

    public var id: String { rawValue }

    /// English tab title shown in the `TabView` tab item (no localization — see
    /// the English-only MVP constraint in CLAUDE.md).
    public var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Providers"
        case .devices: return "Devices"
        case .about: return "About"
        }
    }

    /// SF Symbol name for the tab item icon.
    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "square.stack.3d.up"
        case .devices: return "laptopcomputer"
        case .about: return "info.circle"
        }
    }
}

public extension SettingsTab {
    /// One-line version label for the About tab footer, e.g. "Burnbar 0.1.0".
    /// Reads `BurnbarCore.version` so it tracks `MARKETING_VERSION`.
    static var aboutVersionLabel: String {
        "Burnbar \(BurnbarCore.version)"
    }
}
