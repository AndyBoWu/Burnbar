import XCTest
@testable import BurnbarCore

/// Tests for the Settings preferences model (Epic 1.5.6): theme/refresh option
/// sets, their storage decode/fallback behavior, and the provider-enable gate
/// that `UsageStore.load` uses to skip a disabled parser.
final class PreferencesTests: XCTestCase {

    // MARK: - AppTheme

    func testAppThemeCasesAndDefault() {
        XCTAssertEqual(AppTheme.allCases, [.auto, .light, .dark])
        XCTAssertEqual(AppTheme.default, .auto)
    }

    func testAppThemeTitlesAreEnglishAndNonEmpty() {
        XCTAssertEqual(AppTheme.auto.title, "Automatic")
        XCTAssertEqual(AppTheme.light.title, "Light")
        XCTAssertEqual(AppTheme.dark.title, "Dark")
    }

    func testAppThemeFromStorageDecodesKnownValues() {
        XCTAssertEqual(AppTheme.fromStorage("light"), .light)
        XCTAssertEqual(AppTheme.fromStorage("dark"), .dark)
        XCTAssertEqual(AppTheme.fromStorage("auto"), .auto)
    }

    func testAppThemeFromStorageFallsBackForMissingOrUnknown() {
        XCTAssertEqual(AppTheme.fromStorage(nil), .default)
        XCTAssertEqual(AppTheme.fromStorage("solarized"), .default)
    }

    // MARK: - RefreshInterval

    func testRefreshIntervalCasesAndDefault() {
        XCTAssertEqual(RefreshInterval.allCases, [.oneMinute, .fiveMinutes, .fifteenMinutes])
        XCTAssertEqual(RefreshInterval.default, .fiveMinutes)
    }

    func testRefreshIntervalMinutesAndSeconds() {
        XCTAssertEqual(RefreshInterval.oneMinute.minutes, 1)
        XCTAssertEqual(RefreshInterval.fiveMinutes.minutes, 5)
        XCTAssertEqual(RefreshInterval.fifteenMinutes.minutes, 15)

        XCTAssertEqual(RefreshInterval.oneMinute.seconds, 60)
        XCTAssertEqual(RefreshInterval.fiveMinutes.seconds, 300)
        XCTAssertEqual(RefreshInterval.fifteenMinutes.seconds, 900)
    }

    func testRefreshIntervalTitlesAreEnglishAndNonEmpty() {
        for interval in RefreshInterval.allCases {
            XCTAssertFalse(interval.title.isEmpty, "\(interval) is missing a title")
        }
    }

    func testRefreshIntervalFromStorageFallsBackForMissingOrUnknown() {
        XCTAssertEqual(RefreshInterval.fromStorage("oneMinute"), .oneMinute)
        XCTAssertEqual(RefreshInterval.fromStorage(nil), .default)
        XCTAssertEqual(RefreshInterval.fromStorage("hourly"), .default)
    }

    // MARK: - ProviderPreferences

    func testEnabledProvidersBothOn() {
        let prefs = ProviderPreferences(claudeEnabled: true, codexEnabled: true)
        XCTAssertEqual(prefs.enabledProviders, [.claude, .codex])
        XCTAssertTrue(prefs.isEnabled(.claude))
        XCTAssertTrue(prefs.isEnabled(.codex))
    }

    func testEnabledProvidersClaudeOnly() {
        let prefs = ProviderPreferences(claudeEnabled: true, codexEnabled: false)
        XCTAssertEqual(prefs.enabledProviders, [.claude])
        XCTAssertFalse(prefs.isEnabled(.codex))
    }

    func testEnabledProvidersCodexOnly() {
        let prefs = ProviderPreferences(claudeEnabled: false, codexEnabled: true)
        XCTAssertEqual(prefs.enabledProviders, [.codex])
        XCTAssertFalse(prefs.isEnabled(.claude))
    }

    func testEnabledProvidersBothOffIsEmpty() {
        let prefs = ProviderPreferences(claudeEnabled: false, codexEnabled: false)
        XCTAssertTrue(prefs.enabledProviders.isEmpty)
    }

    func testEnabledProvidersOrderMatchesProviderAllCases() {
        let prefs = ProviderPreferences(claudeEnabled: true, codexEnabled: true)
        XCTAssertEqual(prefs.enabledProviders, Provider.allCases)
    }

    // MARK: - ProviderPreferences.load (UserDefaults)

    /// A clean defaults store (no keys set) reads both providers ON — the
    /// fresh-install default. `bool(forKey:)` would return `false` for a missing
    /// key, so the absence-aware fallback is what's under test here.
    func testLoadDefaultsToBothEnabledWhenUnset() {
        let defaults = makeEphemeralDefaults()
        let prefs = ProviderPreferences.load(from: defaults)
        XCTAssertTrue(prefs.claudeEnabled)
        XCTAssertTrue(prefs.codexEnabled)
    }

    func testLoadHonorsExplicitFalse() {
        let defaults = makeEphemeralDefaults()
        defaults.set(false, forKey: PreferenceKeys.codexEnabled)
        let prefs = ProviderPreferences.load(from: defaults)
        XCTAssertTrue(prefs.claudeEnabled, "Claude unset -> defaults ON")
        XCTAssertFalse(prefs.codexEnabled, "Codex explicitly OFF must be honored")
    }

    func testLoadHonorsExplicitTrue() {
        let defaults = makeEphemeralDefaults()
        defaults.set(true, forKey: PreferenceKeys.claudeEnabled)
        defaults.set(true, forKey: PreferenceKeys.codexEnabled)
        let prefs = ProviderPreferences.load(from: defaults)
        XCTAssertEqual(prefs, ProviderPreferences(claudeEnabled: true, codexEnabled: true))
    }

    func testLoadBothDisabled() {
        let defaults = makeEphemeralDefaults()
        defaults.set(false, forKey: PreferenceKeys.claudeEnabled)
        defaults.set(false, forKey: PreferenceKeys.codexEnabled)
        let prefs = ProviderPreferences.load(from: defaults)
        XCTAssertTrue(prefs.enabledProviders.isEmpty)
    }

    // MARK: - Helpers

    /// An isolated `UserDefaults` suite so tests never touch the real domain.
    /// Removed-then-fresh each call to guarantee a clean slate.
    private func makeEphemeralDefaults() -> UserDefaults {
        let suite = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
