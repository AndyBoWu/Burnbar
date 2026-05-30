import Foundation
import XCTest
@testable import BurnbarCore

final class DailyRollupWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyRollupWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func readLines(machineID: String) throws -> [String] {
        let url = tempDir.appendingPathComponent("\(machineID).jsonl", isDirectory: false)
        let contents = try String(contentsOf: url, encoding: .utf8)
        // An empty file decodes to a single empty component; treat as zero lines.
        if contents.isEmpty { return [] }
        return contents.components(separatedBy: "\n")
    }

    private func decode(_ line: String) throws -> RollupLine {
        try JSONDecoder().decode(RollupLine.self, from: Data(line.utf8))
    }

    // MARK: - Tests

    func testFileURLUsesMachineIDAsName() {
        let writer = DailyRollupWriter(directory: tempDir)
        XCTAssertEqual(
            writer.fileURL(machineID: "abc123def456abcd").lastPathComponent,
            "abc123def456abcd.jsonl"
        )
    }

    func testWritesExpectedLinesRoundTrip() throws {
        let machineID = "machineaabbccdd11"
        let records = [
            UsageRecord(
                provider: .claude,
                model: "claude-opus-4-7",
                day: "2026-05-29",
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 5,
                cacheCreationTokens: 3,
                costUSD: 1.25
            ),
            UsageRecord(
                provider: .codex,
                model: "gpt-5",
                day: "2026-05-29",
                inputTokens: 42,
                costUSD: 0.10
            ),
        ]

        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        let lines = try readLines(machineID: machineID)
        XCTAssertEqual(lines.count, 2)

        // Sorted by (date, provider, model): claude before codex.
        let claude = try decode(lines[0])
        XCTAssertEqual(claude, RollupLine(
            date: "2026-05-29",
            provider: .claude,
            model: "claude-opus-4-7",
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 5,
            cacheCreationTokens: 3,
            costUSD: 1.25
        ))

        // Codex asymmetry preserved: only inputTokens + cost present.
        let codex = try decode(lines[1])
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.inputTokens, 42)
        XCTAssertNil(codex.outputTokens)
        XCTAssertNil(codex.cacheReadTokens)
        XCTAssertNil(codex.cacheCreationTokens)
        XCTAssertEqual(codex.costUSD, 0.10)
    }

    func testGroupsAndSumsByDateProviderModel() throws {
        let machineID = "groupsummachine01"
        let records = [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 100, outputTokens: 10, cacheReadTokens: 1, cacheCreationTokens: 2, costUSD: 1.0
            ),
            // Same bucket — must sum into the line above.
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 50, outputTokens: 5, cacheReadTokens: 4, cacheCreationTokens: 6, costUSD: 0.5
            ),
            // Different model, same day/provider — separate bucket.
            UsageRecord(
                provider: .claude, model: "claude-sonnet-4-7", day: "2026-05-29",
                inputTokens: 7, outputTokens: 7, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0.07
            ),
            // Different day — separate bucket.
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-30",
                inputTokens: 9, outputTokens: 9, cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: 0.09
            ),
        ]

        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        let lines = try readLines(machineID: machineID)
        // 3 distinct (date, provider, model) keys.
        XCTAssertEqual(lines.count, 3)

        let decoded = try lines.map(decode)
        let summed = try XCTUnwrap(decoded.first {
            $0.date == "2026-05-29" && $0.model == "claude-opus-4-7"
        })
        XCTAssertEqual(summed.inputTokens, 150)
        XCTAssertEqual(summed.outputTokens, 15)
        XCTAssertEqual(summed.cacheReadTokens, 5)
        XCTAssertEqual(summed.cacheCreationTokens, 8)
        XCTAssertEqual(try XCTUnwrap(summed.costUSD), 1.5, accuracy: 1e-9)
    }

    func testLineCountEqualsDistinctKeys() throws {
        let machineID = "distinctkeycount1"
        // 5 records collapsing to 3 distinct keys.
        let records = [
            UsageRecord(provider: .claude, model: "claude-opus-4-7", day: "2026-05-29", inputTokens: 1),
            UsageRecord(provider: .claude, model: "claude-opus-4-7", day: "2026-05-29", inputTokens: 1),
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 1),
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-30", inputTokens: 1),
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-30", inputTokens: 1),
        ]
        let distinctKeys = Set(records.map { "\($0.day)|\($0.provider.rawValue)|\($0.model)" })

        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        XCTAssertEqual(try readLines(machineID: machineID).count, distinctKeys.count)
    }

    func testEmptyInputWritesEmptyFile() throws {
        let machineID = "emptyinputmachine"
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: [], machineID: machineID)

        let url = tempDir.appendingPathComponent("\(machineID).jsonl", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 0)
        XCTAssertEqual(try readLines(machineID: machineID).count, 0)
    }

    func testOverwritesExistingFile() throws {
        let machineID = "overwritemachine0"
        let writer = DailyRollupWriter(directory: tempDir)

        try writer.write(
            records: [UsageRecord(provider: .claude, model: "claude-opus-4-7", day: "2026-05-29", inputTokens: 1)],
            machineID: machineID
        )
        XCTAssertEqual(try readLines(machineID: machineID).count, 1)

        // Second run with fewer records must fully replace, not append.
        try writer.write(records: [], machineID: machineID)
        XCTAssertEqual(try readLines(machineID: machineID).count, 0)
    }

    /// The written JSON keys are a hard privacy allowlist — no `cwd`, paths,
    /// `git_*`, `title`, `preview`, `content`, etc. ever appear.
    func testJSONKeysMatchAllowlistExactly() throws {
        let machineID = "allowlistmachine1"
        let records = [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 5, cacheCreationTokens: 3, costUSD: 1.25
            ),
        ]
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        let line = try XCTUnwrap(readLines(machineID: machineID).first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )

        let expectedKeys: Set<String> = [
            "date", "provider", "model",
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens",
            "costUSD",
        ]
        XCTAssertEqual(Set(object.keys), expectedKeys)

        // Explicitly assert the forbidden identifiers never leak in.
        let forbidden = [
            "cwd", "path", "projectPath", "project", "git_branch", "git_origin_url",
            "git_sha", "title", "first_user_message", "preview", "content", "message",
            "text", "machineID", "machine_id",
        ]
        for key in forbidden {
            XCTAssertNil(object[key], "rollup line must not contain '\(key)'")
        }
    }

    /// Nil token categories are omitted from the JSON entirely (not encoded as
    /// `null` or `0`), preserving the Codex asymmetry on the wire.
    func testCodexNilFieldsAreOmittedFromJSON() throws {
        let machineID = "codexnilmachine01"
        let records = [
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 42),
        ]
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        let line = try XCTUnwrap(readLines(machineID: machineID).first)
        XCTAssertFalse(line.contains("outputTokens"))
        XCTAssertFalse(line.contains("cacheReadTokens"))
        XCTAssertFalse(line.contains("cacheCreationTokens"))
        XCTAssertFalse(line.contains("costUSD"))
        XCTAssertTrue(line.contains("\"inputTokens\":42"))
    }

    /// A bucket where one record supplies a cache value and another does not must
    /// surface the value (nil treated as 0), not stay absent.
    func testMixedNilAndPresentCacheSumsRatherThanDropping() throws {
        let machineID = "mixednilmachine01"
        let records = [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 10, outputTokens: nil, cacheReadTokens: nil, cacheCreationTokens: nil, costUSD: nil
            ),
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 10, outputTokens: 5, cacheReadTokens: 7, cacheCreationTokens: nil, costUSD: 0.3
            ),
        ]
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)

        let line = try decode(try XCTUnwrap(readLines(machineID: machineID).first))
        XCTAssertEqual(line.inputTokens, 20)
        XCTAssertEqual(line.outputTokens, 5)
        XCTAssertEqual(line.cacheReadTokens, 7)
        // Both records left cacheCreation nil → stays nil.
        XCTAssertNil(line.cacheCreationTokens)
        XCTAssertEqual(try XCTUnwrap(line.costUSD), 0.3, accuracy: 1e-9)
    }

    /// The injected write primitive is what actually touches disk — verifies the
    /// directory + filename plumbing without relying on the default FS write.
    func testUsesInjectedWriteData() throws {
        final class Capture: @unchecked Sendable {
            var url: URL?
            var data: Data?
        }
        let capture = Capture()
        let writer = DailyRollupWriter(directory: tempDir) { data, url in
            capture.data = data
            capture.url = url
        }
        try writer.write(
            records: [UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 1)],
            machineID: "injectedmachine01"
        )
        XCTAssertEqual(capture.url, tempDir.appendingPathComponent("injectedmachine01.jsonl"))
        XCTAssertNotNil(capture.data)
    }
}
