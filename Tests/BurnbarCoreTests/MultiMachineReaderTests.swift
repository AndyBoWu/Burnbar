import Foundation
import XCTest
@testable import BurnbarCore

final class MultiMachineReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiMachineReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Write a real `{machineID}.jsonl` via the production writer, so the test
    /// reads exactly the on-disk shape the reader must parse.
    @discardableResult
    private func writeRollup(machineID: String, records: [UsageRecord]) throws -> URL {
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: records, machineID: machineID)
        return tempDir.appendingPathComponent("\(machineID).jsonl", isDirectory: false)
    }

    private func writeRaw(filename: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(filename, isDirectory: false)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func sampleRecords(day: String, inputTokens: Int) -> [UsageRecord] {
        [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: day,
                inputTokens: inputTokens, outputTokens: 10, cacheReadTokens: 5,
                cacheCreationTokens: 3, costUSD: 1.0
            ),
            UsageRecord(provider: .codex, model: "gpt-5", day: day, inputTokens: 42, costUSD: 0.1)
        ]
    }

    // MARK: - Tests

    func testEmptyDirectoryYieldsEmptyResult() {
        let reader = MultiMachineReader(directory: tempDir)
        XCTAssertEqual(reader.readMachines(), [])
        XCTAssertTrue(reader.readAll().isEmpty)
    }

    func testMissingDirectoryYieldsEmptyResult() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let reader = MultiMachineReader(directory: missing)
        XCTAssertEqual(reader.readMachines(), [])
        XCTAssertTrue(reader.readAll().isEmpty)
    }

    func testReadsTwoMachineFiles() throws {
        try writeRollup(machineID: "machineaaaaaaaa01", records: sampleRecords(day: "2026-05-29", inputTokens: 100))
        try writeRollup(machineID: "machinebbbbbbbb02", records: sampleRecords(day: "2026-05-30", inputTokens: 200))

        let reader = MultiMachineReader(directory: tempDir)
        let machines = reader.readMachines()

        XCTAssertEqual(machines.count, 2)
        // Sorted by machineID for determinism.
        XCTAssertEqual(machines.map(\.machineID), ["machineaaaaaaaa01", "machinebbbbbbbb02"])

        // Each machine round-trips both records (claude + codex).
        XCTAssertEqual(machines[0].records.count, 2)
        XCTAssertEqual(machines[1].records.count, 2)

        let map = reader.readAll()
        XCTAssertEqual(Set(map.keys), ["machineaaaaaaaa01", "machinebbbbbbbb02"])
        XCTAssertEqual(map["machineaaaaaaaa01"]?.count, 2)
    }

    func testRecordsRoundTripThroughRollup() throws {
        try writeRollup(machineID: "roundtripmachine1", records: sampleRecords(day: "2026-05-29", inputTokens: 100))

        let reader = MultiMachineReader(directory: tempDir)
        let machine = try XCTUnwrap(reader.readMachines().first)

        let claude = try XCTUnwrap(machine.records.first { $0.provider == .claude })
        XCTAssertEqual(claude.model, "claude-opus-4-7")
        XCTAssertEqual(claude.day, "2026-05-29")
        XCTAssertEqual(claude.inputTokens, 100)
        XCTAssertEqual(claude.outputTokens, 10)
        XCTAssertEqual(claude.cacheReadTokens, 5)
        XCTAssertEqual(claude.cacheCreationTokens, 3)
        XCTAssertEqual(try XCTUnwrap(claude.costUSD), 1.0, accuracy: 1e-9)

        // Codex asymmetry survives the round-trip: only input + cost present.
        let codex = try XCTUnwrap(machine.records.first { $0.provider == .codex })
        XCTAssertEqual(codex.inputTokens, 42)
        XCTAssertNil(codex.outputTokens)
        XCTAssertNil(codex.cacheReadTokens)
        XCTAssertNil(codex.cacheCreationTokens)
        XCTAssertEqual(try XCTUnwrap(codex.costUSD), 0.1, accuracy: 1e-9)
    }

    func testCorruptFileIsSkippedAndGoodDataSurvives() throws {
        try writeRollup(machineID: "goodmachineaaa001", records: sampleRecords(day: "2026-05-29", inputTokens: 100))
        // Not valid JSON on any line.
        try writeRaw(filename: "corruptmachine002.jsonl", contents: "{not valid json at all\nalso garbage}")

        let reader = MultiMachineReader(directory: tempDir)
        let machines = reader.readMachines()

        // Both files surface as machines; the corrupt one just yields zero records.
        XCTAssertEqual(machines.count, 2)

        let good = try XCTUnwrap(machines.first { $0.machineID == "goodmachineaaa001" })
        XCTAssertEqual(good.records.count, 2)

        let corrupt = try XCTUnwrap(machines.first { $0.machineID == "corruptmachine002" })
        XCTAssertEqual(corrupt.records, [], "corrupt lines must be skipped, never crash the read")
    }

    func testPartialFileKeepsValidLinesAndSkipsBadOnes() throws {
        let valid = RollupLine(
            date: "2026-05-29", provider: .claude, model: "claude-opus-4-7",
            inputTokens: 7, outputTokens: 2, cacheReadTokens: nil, cacheCreationTokens: nil, costUSD: 0.05
        )
        let validData = try JSONEncoder().encode(valid)
        let validLine = try XCTUnwrap(String(bytes: validData, encoding: .utf8))
        // One good line, one garbage line, one good line.
        let contents = [validLine, "{ this is broken", validLine].joined(separator: "\n")
        try writeRaw(filename: "partialmachine003.jsonl", contents: contents)

        let reader = MultiMachineReader(directory: tempDir)
        let machine = try XCTUnwrap(reader.readMachines().first)
        // Two valid lines decode; the broken middle line is skipped.
        XCTAssertEqual(machine.records.count, 2)
        XCTAssertTrue(machine.records.allSatisfy { $0.inputTokens == 7 })
    }

    func testTmpStagingFilesAreIgnored() throws {
        try writeRollup(machineID: "realmachineaaa004", records: sampleRecords(day: "2026-05-29", inputTokens: 100))
        // 2.2.3 atomic-staging artifact — must not be read as a machine.
        try writeRaw(filename: "realmachineaaa004.jsonl.tmp", contents: "garbage that should never be parsed")

        let reader = MultiMachineReader(directory: tempDir)
        let machines = reader.readMachines()

        XCTAssertEqual(machines.map(\.machineID), ["realmachineaaa004"])
        XCTAssertEqual(machines.first?.records.count, 2)
    }

    func testEmptyRollupFileYieldsMachineWithNoRecords() throws {
        // A machine that wrote zero usage produces a zero-byte file (writer contract).
        try writeRollup(machineID: "emptymachineaa005", records: [])

        let reader = MultiMachineReader(directory: tempDir)
        let machine = try XCTUnwrap(reader.readMachines().first)
        XCTAssertEqual(machine.machineID, "emptymachineaa005")
        XCTAssertEqual(machine.records, [])
        XCTAssertNil(machine.lastRecordDay)
    }

    func testLastRecordDayIsLatestDay() throws {
        let records = [
            UsageRecord(provider: .claude, model: "claude-opus-4-7", day: "2026-05-28", inputTokens: 1),
            UsageRecord(provider: .claude, model: "claude-opus-4-7", day: "2026-05-30", inputTokens: 1),
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 1)
        ]
        try writeRollup(machineID: "lastdaymachine006", records: records)

        let reader = MultiMachineReader(directory: tempDir)
        let machine = try XCTUnwrap(reader.readMachines().first)
        XCTAssertEqual(machine.lastRecordDay, "2026-05-30")
    }

    func testNonJSONLFilesAreIgnored() throws {
        try writeRollup(machineID: "jsonlmachineaa007", records: sampleRecords(day: "2026-05-29", inputTokens: 100))
        try writeRaw(filename: "README.md", contents: "# not a rollup")
        try writeRaw(filename: "notes.txt", contents: "ignore me")

        let reader = MultiMachineReader(directory: tempDir)
        XCTAssertEqual(reader.readMachines().map(\.machineID), ["jsonlmachineaa007"])
    }
}
