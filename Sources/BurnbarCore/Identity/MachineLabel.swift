import Foundation

/// A human-readable, user-editable name for this Mac.
///
/// The `machine_id` from 2.1.1 is an opaque hash — unfriendly in the M2
/// multi-machine UI. This store returns a friendly label (defaulting to the
/// system computer name) that the user can rename, so the combined-view and
/// Devices UIs (2.1.3 / #31) can show "MacBook Pro" instead of a hex string.
///
/// Persistence model: when the user sets an override it is stored under
/// `defaultsKey` and wins over the system name; clearing the override (empty /
/// whitespace-only input) removes the key and reverts to the system default.
/// Only Burnbar's own `xyz.andybowu.Burnbar.*` `UserDefaults` namespace is
/// touched — consistent with the privacy thesis.
///
/// Both the default-name source and the `UserDefaults` instance are injected so
/// every branch is unit-testable without depending on the host machine's name.
/// The store is a small value type holding only its injected dependencies; its
/// only mutating effect is writing through to the thread-safe `UserDefaults`.
/// (It is intentionally not declared `Sendable`: `UserDefaults` is thread-safe
/// but not `Sendable`-annotated by Apple, and forcing the conformance would
/// require an `@unchecked` escape hatch. Construct a store where you use it.)
/// No UI lives here; SwiftUI binding/observation is layered on in 2.1.3 (#31).
public struct MachineLabel {
    /// `UserDefaults` key the user's override label is persisted under.
    public static let defaultsKey = "xyz.andybowu.Burnbar.machineLabel"

    private let defaults: UserDefaults
    private let systemName: @Sendable () -> String

    /// - Parameters:
    ///   - defaults: Storage for the user override (injectable for tests).
    ///   - systemName: Source of the system computer name used as the default
    ///     (injectable for tests). Defaults to `Host.current().localizedName`,
    ///     falling back to `ProcessInfo.processInfo.hostName`.
    public init(
        defaults: UserDefaults = .standard,
        systemName: @escaping @Sendable () -> String = MachineLabel.systemComputerName
    ) {
        self.defaults = defaults
        self.systemName = systemName
    }

    /// The label to display: the user's override if one is set, otherwise the
    /// system computer name.
    public var label: String {
        if let override = storedOverride {
            return override
        }
        return systemName()
    }

    /// The persisted user override, or `nil` when none is set. Trimmed/empty
    /// values are treated as "no override" so a cleared field reverts to the
    /// system default even if a stray empty string was ever written.
    public var storedOverride: String? {
        guard let raw = defaults.string(forKey: Self.defaultsKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Set the user's label override.
    ///
    /// Input is trimmed of surrounding whitespace/newlines. Empty (or
    /// whitespace-only) input clears the override — the label reverts to the
    /// system computer name. The change is written through to `UserDefaults`,
    /// so a freshly constructed store sees the same value.
    public func rename(to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(trimmed, forKey: Self.defaultsKey)
        }
    }

    /// The system computer name: `Host.current().localizedName`, falling back to
    /// `ProcessInfo.processInfo.hostName` when the localized name is unavailable.
    public static func systemComputerName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
