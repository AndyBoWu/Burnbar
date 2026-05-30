import Foundation
import XCTest
@testable import BurnbarCore

/// Drives ``StaleMachineDetector`` to assert 2.3.4's Definition of Done: the stale
/// flag is computed correctly against an injected `now` (31 days ago = stale,
/// 29 days = fresh, exactly-30 boundary = fresh), and the combined merge excludes
/// stale machines by default but includes them when `includeStale == true`.
final class StaleMachineDetectorTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed reference "now" so every threshold assertion is deterministic.
    private let now = ISO8601DateFormatter().date(from: "2026-05-30T00:00:00Z")!

    /// `now` shifted back by `days` whole days.
    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "StaleMachineDetectorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A registry seeded with the given `(machine_id, lastSeen)` sightings.
    private func registry(_ sightings: [String: Date]) -> MachineRegistry {
        let registry = MachineRegistry(defaults: freshDefaults())
        for (id, lastSeen) in sightings {
            registry.upsert(machineID: id, lastSeen: lastSeen)
        }
        return registry
    }

    private func claude(day: String, input: Int) -> UsageRecord {
        UsageRecord(provider: .claude, model: "claude-opus-4-7", day: day, inputTokens: input)
    }

    // MARK: - isStale boundary (DoD: 31 stale, 29 fresh, exactly-30 boundary)

    func testActivity31DaysAgoIsStale() {
        let detector = StaleMachineDetector()
        XCTAssertTrue(detector.isStale(lastActivity: daysAgo(31), now: now))
    }

    func testActivity29DaysAgoIsFresh() {
        let detector = StaleMachineDetector()
        XCTAssertFalse(detector.isStale(lastActivity: daysAgo(29), now: now))
    }

    func testActivityExactly30DaysAgoIsFresh() {
        // Boundary: exactly the threshold (to the second) is still fresh — only
        // *older* than 30 days is stale.
        let detector = StaleMachineDetector()
        XCTAssertFalse(detector.isStale(lastActivity: daysAgo(30), now: now))
    }

    func testActivityJustPastBoundaryIsStale() {
        // One second past exactly-30-days is stale; one second short is fresh.
        let detector = StaleMachineDetector()
        let cutoff = daysAgo(30)
        XCTAssertTrue(detector.isStale(lastActivity: cutoff.addingTimeInterval(-1), now: now))
        XCTAssertFalse(detector.isStale(lastActivity: cutoff.addingTimeInterval(1), now: now))
    }

    func testThresholdConstantIs30Days() {
        XCTAssertEqual(StaleMachineDetector.staleThresholdDays, 30)
    }

    // MARK: - Flagging via registry lastSeen

    func testStaleMachineIDsFlagsOnlyTheStaleMachine() {
        let detector = StaleMachineDetector()
        let registry = registry([
            "stale-mac": daysAgo(31),
            "fresh-mac": daysAgo(29)
        ])
        let byMachine: [String: [UsageRecord]] = [
            "stale-mac": [claude(day: "2026-04-29", input: 100)],
            "fresh-mac": [claude(day: "2026-05-01", input: 200)]
        ]

        let stale = detector.staleMachineIDs(in: byMachine, registry: registry, now: now)
        XCTAssertEqual(stale, ["stale-mac"])
    }

    func testRegistryLastSeenTakesPrecedenceOverRecordDay() {
        // The registry says the machine was seen recently (fresh) even though its
        // records are old — the registry is authoritative.
        let detector = StaleMachineDetector()
        let registry = registry(["m": daysAgo(5)])
        let byMachine: [String: [UsageRecord]] = ["m": [claude(day: "2026-01-01", input: 100)]]

        let stale = detector.staleMachineIDs(in: byMachine, registry: registry, now: now)
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - Flagging falls back to latest record day when registry is silent

    func testFallsBackToLatestRecordDayWhenMachineNotInRegistry() {
        let detector = StaleMachineDetector()
        let emptyRegistry = MachineRegistry(defaults: freshDefaults())
        let byMachine: [String: [UsageRecord]] = [
            // Latest day is 2026-04-01 → ~59 days before now → stale.
            "ghost-old": [claude(day: "2026-02-01", input: 1), claude(day: "2026-04-01", input: 2)],
            // Latest day is 2026-05-20 → ~10 days before now → fresh.
            "ghost-recent": [claude(day: "2026-05-20", input: 3)]
        ]

        let stale = detector.staleMachineIDs(in: byMachine, registry: emptyRegistry, now: now)
        XCTAssertEqual(stale, ["ghost-old"])
    }

    func testMachineWithNoRegistryAndNoRecordsIsFresh() {
        // Cannot judge staleness with no data → never silently excluded.
        let detector = StaleMachineDetector()
        let emptyRegistry = MachineRegistry(defaults: freshDefaults())
        let byMachine: [String: [UsageRecord]] = ["empty": []]

        let stale = detector.staleMachineIDs(in: byMachine, registry: emptyRegistry, now: now)
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - Combined merge excludes stale by default / includes on demand

    func testMergeExcludesStaleMachineByDefault() {
        let detector = StaleMachineDetector()
        let registry = registry([
            "stale-mac": daysAgo(31),
            "fresh-mac": daysAgo(2)
        ])
        let byMachine: [String: [UsageRecord]] = [
            "stale-mac": [claude(day: "2026-04-29", input: 100)],
            "fresh-mac": [claude(day: "2026-05-28", input: 200)]
        ]

        let result = detector.merge(byMachine, registry: registry, now: now)

        // Only the fresh machine survives — combined holds just its 200 input.
        XCTAssertEqual(result.combined.count, 1)
        XCTAssertEqual(result.combined.first?.day, "2026-05-28")
        XCTAssertEqual(result.combined.first?.inputTokens, 200)
        // Stale machine is dropped from the drilldown too, so combined and byMachine agree.
        XCTAssertEqual(Set(result.byMachine.keys), ["fresh-mac"])
        XCTAssertNil(result.byMachine["stale-mac"])
    }

    func testMergeIncludesStaleMachineWhenRequested() {
        let detector = StaleMachineDetector()
        let registry = registry([
            "stale-mac": daysAgo(31),
            "fresh-mac": daysAgo(2)
        ])
        let byMachine: [String: [UsageRecord]] = [
            "stale-mac": [claude(day: "2026-04-29", input: 100)],
            "fresh-mac": [claude(day: "2026-05-28", input: 200)]
        ]

        let result = detector.merge(byMachine, registry: registry, now: now, includeStale: true)

        // Both machines contribute → two distinct day records, 300 input total.
        XCTAssertEqual(result.combined.count, 2)
        let totalInput = result.combined.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(totalInput, 300)
        XCTAssertEqual(Set(result.byMachine.keys), ["stale-mac", "fresh-mac"])
    }

    func testMergeWithNoStaleMachinesEqualsPlainReconcile() {
        let detector = StaleMachineDetector()
        let registry = registry([
            "a": daysAgo(1),
            "b": daysAgo(10)
        ])
        let byMachine: [String: [UsageRecord]] = [
            "a": [claude(day: "2026-05-29", input: 100)],
            "b": [claude(day: "2026-05-20", input: 200)]
        ]

        let staleAware = detector.merge(byMachine, registry: registry, now: now)
        let plain = Reconciler().merge(byMachine)
        XCTAssertEqual(staleAware, plain)
    }

    func testMergeAllStaleYieldsEmptyCombinedByDefault() {
        let detector = StaleMachineDetector()
        let registry = registry([
            "old1": daysAgo(40),
            "old2": daysAgo(100)
        ])
        let byMachine: [String: [UsageRecord]] = [
            "old1": [claude(day: "2026-04-01", input: 100)],
            "old2": [claude(day: "2026-01-01", input: 200)]
        ]

        let excluded = detector.merge(byMachine, registry: registry, now: now)
        XCTAssertTrue(excluded.combined.isEmpty)
        XCTAssertTrue(excluded.byMachine.isEmpty)

        // ...but every machine returns when explicitly included.
        let included = detector.merge(byMachine, registry: registry, now: now, includeStale: true)
        XCTAssertEqual(included.combined.count, 2)
    }

    // MARK: - IncludeStaleMachinesPreference

    func testIncludeStalePreferenceDefaultsToFalse() {
        let preference = IncludeStaleMachinesPreference(defaults: freshDefaults())
        XCTAssertFalse(preference.isEnabled)
    }

    func testIncludeStalePreferencePersistsToggle() {
        let defaults = freshDefaults()
        let preference = IncludeStaleMachinesPreference(defaults: defaults)
        preference.isEnabled = true
        XCTAssertTrue(preference.isEnabled)

        // A fresh wrapper over the same defaults reads the persisted value, and the
        // canonical key is the one the detector references.
        let reloaded = IncludeStaleMachinesPreference(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: StaleMachineDetector.includeStalePreferenceKey))
    }
}
