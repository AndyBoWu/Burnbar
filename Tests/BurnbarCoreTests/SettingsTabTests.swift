import XCTest
@testable import BurnbarCore

/// Tests for the Settings window's tab model (Epic 1.5.5 scaffold).
///
/// The view renders one tab per `SettingsTab` case, so these guard the exact
/// set, order, English labels, and SF Symbol names the UI depends on.
final class SettingsTabTests: XCTestCase {
    /// Exactly three tabs, in display order: General, Providers, About.
    func testThreeTabsInOrder() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .providers, .about])
    }

    /// English titles match the ticket's General | Providers | About spec.
    func testTitles() {
        XCTAssertEqual(SettingsTab.general.title, "General")
        XCTAssertEqual(SettingsTab.providers.title, "Providers")
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

    /// The About version label tracks `BurnbarCore.version`.
    func testAboutVersionLabelTracksCoreVersion() {
        XCTAssertEqual(SettingsTab.aboutVersionLabel, "Burnbar \(BurnbarCore.version)")
    }
}
