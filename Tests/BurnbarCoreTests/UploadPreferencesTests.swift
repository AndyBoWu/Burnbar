import Foundation
import XCTest
@testable import BurnbarCore

/// Exercises ``UploadPreferences`` — the persisted opt-in gate, last-upload
/// timestamp, and public GitHub login for the Settings → Leaderboard tab
/// (sub-ticket 3.3.4).
///
/// The Definition of Done's gating rule lives here: uploads are **opt-in,
/// default-OFF**, so an absent flag reads as OFF (no upload until explicit
/// consent), and only an explicit `true` enables them. All reads/writes go through
/// an isolated, throwaway `UserDefaults` suite so the tests never touch the real
/// app domain.
final class UploadPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "xyz.andybowu.Burnbar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Opt-in gate (default OFF)

    func testOptedInDefaultsToOffWhenUnset() {
        // A fresh install has never written the flag — uploads must be OFF.
        XCTAssertFalse(UploadPreferences.isOptedIn(in: defaults))
        XCTAssertFalse(UploadPreferences.optedInByDefault)
    }

    func testOptedInReadsTrueWhenSet() {
        defaults.set(true, forKey: UploadPreferences.optedInKey)
        XCTAssertTrue(UploadPreferences.isOptedIn(in: defaults))
    }

    func testOptingOutBlocksUploads() {
        // Explicitly OFF (the user toggled off) reads as not opted in.
        defaults.set(false, forKey: UploadPreferences.optedInKey)
        XCTAssertFalse(UploadPreferences.isOptedIn(in: defaults))
    }

    func testTogglePersistsAcrossReads() {
        defaults.set(true, forKey: UploadPreferences.optedInKey)
        XCTAssertTrue(UploadPreferences.isOptedIn(in: defaults))
        defaults.set(false, forKey: UploadPreferences.optedInKey)
        XCTAssertFalse(UploadPreferences.isOptedIn(in: defaults))
    }

    // MARK: - Last-upload timestamp

    func testLastUploadAtIsNilWhenNeverUploaded() {
        XCTAssertNil(UploadPreferences.lastUploadAt(in: defaults))
    }

    func testSetAndReadLastUploadAt() {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        UploadPreferences.setLastUploadAt(when, in: defaults)
        XCTAssertEqual(UploadPreferences.lastUploadAt(in: defaults), when)
    }

    // MARK: - GitHub login (public, for the profile link)

    func testGithubLoginIsNilWhenUnset() {
        XCTAssertNil(UploadPreferences.githubLogin(in: defaults))
    }

    func testGithubLoginIsNilWhenEmpty() {
        defaults.set("", forKey: UploadPreferences.githubLoginKey)
        XCTAssertNil(UploadPreferences.githubLogin(in: defaults))
    }

    func testGithubLoginReadsStoredValue() {
        defaults.set("octocat", forKey: UploadPreferences.githubLoginKey)
        XCTAssertEqual(UploadPreferences.githubLogin(in: defaults), "octocat")
    }

    // MARK: - Key stability

    /// The keys are persisted tokens shared with the scheduler/UI — guard against
    /// an accidental rename that would silently reset consent.
    func testStorageKeysAreStable() {
        XCTAssertEqual(UploadPreferences.optedInKey, "xyz.andybowu.Burnbar.leaderboard.optedIn")
        XCTAssertEqual(
            UploadPreferences.lastUploadAtKey,
            "xyz.andybowu.Burnbar.leaderboard.last-upload-success-at"
        )
        XCTAssertEqual(
            UploadPreferences.githubLoginKey,
            "xyz.andybowu.Burnbar.leaderboard.github-login"
        )
    }
}
