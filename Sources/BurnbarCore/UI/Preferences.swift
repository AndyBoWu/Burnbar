import Foundation

// Pure, view-agnostic models + storage keys for the Settings window's controls
// (Epic 1.5.6). Living in `BurnbarCore` keeps the option sets, defaults, and the
// "which providers are enabled" gate unit-testable without launching the app —
// the SwiftUI `SettingsView` binds to these via `@AppStorage`, and `UsageStore`
// reads the same keys to skip a disabled provider.
//
// English-only literals throughout (no String Catalog / `String(localized:)`),
// per the MVP constraint in CLAUDE.md.

/// The `UserDefaults` keys every persisted Settings control reads/writes, plus
/// the defaults that apply before the user has touched a control.
///
/// Centralizing the keys here (rather than scattering string literals across the
/// view and the store) is the contract that lets `SettingsView`'s `@AppStorage`
/// and `UsageStore`'s `UserDefaults` reads agree on the same slots.
public enum PreferenceKeys {
    /// Selected app appearance (`AppTheme.rawValue`).
    public static let theme = "xyz.andybowu.Burnbar.theme"
    /// Selected refresh cadence (`RefreshInterval.rawValue`).
    public static let refreshInterval = "xyz.andybowu.Burnbar.refreshInterval"
    /// Whether the Claude parser runs (`Bool`).
    public static let claudeEnabled = "xyz.andybowu.Burnbar.provider.claude.enabled"
    /// Whether the Codex parser runs (`Bool`).
    public static let codexEnabled = "xyz.andybowu.Burnbar.provider.codex.enabled"
    /// Whether the one-time, first-launch menu-bar onboarding cue has already
    /// been shown (`Bool`). Absent/`false` on a fresh install; set `true` after
    /// the cue runs so it never recurs. See `MenuBarController`.
    public static let firstRunOnboardingShown = "xyz.andybowu.Burnbar.firstRunOnboardingShown"

    /// Both providers default ON: a fresh install reads everything it can until
    /// the user opts a provider out.
    public static let providerEnabledByDefault = true
}

/// The app appearance the user picks in General → Theme.
///
/// `auto` follows the system; `light`/`dark` force an `NSAppearance`. The raw
/// values are stable storage tokens — never rename them or persisted settings
/// would silently reset on upgrade.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system appearance (no override).
    case auto
    /// Force the light appearance.
    case light
    /// Force the dark appearance.
    case dark

    public var id: String { rawValue }

    /// The default before the user picks a theme: follow the system.
    public static let `default`: AppTheme = .auto

    /// English label shown in the theme picker.
    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Decode a stored raw value, falling back to ``default`` for an absent or
    /// unrecognized token (e.g. a value written by a newer build).
    public static func fromStorage(_ raw: String?) -> AppTheme {
        guard let raw, let theme = AppTheme(rawValue: raw) else { return .default }
        return theme
    }
}

/// How often `UsageStore` re-reads usage in the background (General → Refresh
/// rate). The raw values are stable storage tokens.
///
/// Day-granular usage doesn't change second-to-second, so the cadence is coarse
/// (minutes) — enough to keep the menu-bar total fresh without hammering the
/// JSONL/SQLite reads.
public enum RefreshInterval: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    public var id: String { rawValue }

    /// The default cadence before the user picks one.
    public static let `default`: RefreshInterval = .fiveMinutes

    /// Whole minutes between background refreshes.
    public var minutes: Int {
        switch self {
        case .oneMinute: return 1
        case .fiveMinutes: return 5
        case .fifteenMinutes: return 15
        }
    }

    /// Cadence in seconds, ready to feed a `Timer`/`Task.sleep`.
    public var seconds: TimeInterval { TimeInterval(minutes * 60) }

    /// English label shown in the refresh-rate picker.
    public var title: String {
        switch self {
        case .oneMinute: return "Every minute"
        case .fiveMinutes: return "Every 5 minutes"
        case .fifteenMinutes: return "Every 15 minutes"
        }
    }

    /// Decode a stored raw value, falling back to ``default`` for an absent or
    /// unrecognized token.
    public static func fromStorage(_ raw: String?) -> RefreshInterval {
        guard let raw, let interval = RefreshInterval(rawValue: raw) else { return .default }
        return interval
    }
}

/// The persisted provider on/off state, resolved into the set of providers a
/// load should actually read.
///
/// This is the pure gate behind the Providers tab toggles: `SettingsView` writes
/// the two `Bool` flags via `@AppStorage`, and `UsageStore.load` asks
/// ``enabledProviders(in:)`` which parsers to run so a disabled provider is
/// skipped entirely (its tile then drops out of the popover for free, since the
/// aggregate has no records for it).
public struct ProviderPreferences: Equatable, Sendable {
    /// Whether the Claude parser should run.
    public let claudeEnabled: Bool
    /// Whether the Codex parser should run.
    public let codexEnabled: Bool

    public init(claudeEnabled: Bool, codexEnabled: Bool) {
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
    }

    /// Whether the given provider's parser should run.
    public func isEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        }
    }

    /// The providers a load should read, in `Provider.allCases` order. Empty when
    /// the user has disabled both (a valid, if quiet, state).
    public var enabledProviders: [Provider] {
        Provider.allCases.filter(isEnabled)
    }

    /// Read the persisted flags from `UserDefaults`, treating an *absent* key as
    /// ``PreferenceKeys/providerEnabledByDefault`` (ON) — a fresh install reads
    /// both providers. `UserDefaults.bool(forKey:)` returns `false` for a missing
    /// key, so absence is detected via `object(forKey:)` before falling back.
    public static func load(from defaults: UserDefaults = .standard) -> ProviderPreferences {
        ProviderPreferences(
            claudeEnabled: flag(PreferenceKeys.claudeEnabled, in: defaults),
            codexEnabled: flag(PreferenceKeys.codexEnabled, in: defaults)
        )
    }

    private static func flag(_ key: String, in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return PreferenceKeys.providerEnabledByDefault
        }
        return defaults.bool(forKey: key)
    }
}
