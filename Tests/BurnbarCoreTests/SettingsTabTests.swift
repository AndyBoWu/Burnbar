import XCTest
@testable import BurnbarCore

/// Tests for the Settings window's tab model (Epic 1.5.5 scaffold; `devices`
/// added in 2.1.3).
///
/// The view renders one tab per `SettingsTab` case, so these guard the exact
/// set, order, English labels, and SF Symbol names the UI depends on.
final class SettingsTabTests: XCTestCase {
    /// Exactly five tabs, in display order: General, Providers, Devices,
    /// Leaderboard, About (Leaderboard added in 3.3.4).
    func testFiveTabsInOrder() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .providers, .devices, .leaderboard, .about])
    }

    /// English titles match the General | Providers | Devices | Leaderboard |
    /// About spec.
    func testTitles() {
        XCTAssertEqual(SettingsTab.general.title, "General")
        XCTAssertEqual(SettingsTab.providers.title, "Providers")
        XCTAssertEqual(SettingsTab.devices.title, "Devices")
        XCTAssertEqual(SettingsTab.leaderboard.title, "Leaderboard")
        XCTAssertEqual(SettingsTab.about.title, "About")
    }

    /// Every tab has a non-empty SF Symbol for its `.tabItem` icon.
    func testEveryTabHasSystemImage() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) is missing an SF Symbol")
        }
    }

    /// Tab `id` is the raw value, so SwiftUI `ForEach`/`.tag` identity is stable.
    func testIdentityIsRawValue() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
        }
    }

    /// Raw values are the stable storage/deep-link tokens — guard the Devices
    /// and Leaderboard cases against an accidental rename that would break
    /// persisted selection.
    func testStableRawValues() {
        XCTAssertEqual(SettingsTab.devices.rawValue, "devices")
        XCTAssertEqual(SettingsTab.leaderboard.rawValue, "leaderboard")
    }

    /// The About version label tracks `BurnbarCore.version`.
    func testAboutVersionLabelTracksCoreVersion() {
        XCTAssertEqual(SettingsTab.aboutVersionLabel, "Burnbar \(BurnbarCore.version)")
    }
}
