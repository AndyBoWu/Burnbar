import Foundation

/// Namespace + version marker for Burnbar's provider-agnostic core.
///
/// Everything that must be unit-tested without launching the app lives in
/// this module: the unified `UsageRecord` model (Epic 1.2.3), the Claude and
/// Codex parsers (Epics 1.2 / 1.3), and the cost engine (Epic 1.4).
///
/// The app target (`Burnbar`) is a thin SwiftUI shell on top of this.
public enum BurnbarCore {
    /// Marketing version, kept in sync with `MARKETING_VERSION` in project.yml.
    public static let version = "0.1.0"
}
