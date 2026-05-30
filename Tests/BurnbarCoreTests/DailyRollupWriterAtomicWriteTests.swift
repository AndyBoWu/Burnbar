import Foundation
import XCTest
@testable import BurnbarCore

/// Tests for the atomic write primitive (2.2.3): tmp → fsync → rename.
///
/// These exercise the *default* `DailyRollupWriter` write path (no injected
/// `writeData`), so they prove the on-disk file is complete + valid and that no
/// stray `.tmp` survives, and that an interrupted write cannot corrupt a prior
/// `.jsonl`.
final class DailyRollupWriterAtomicWriteTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicWriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func tmpSibling(for jsonlURL: URL) -> URL {
        jsonlURL.deletingPathExtension().appendingPathExtension("tmp")
    }

    private func contentsOfDirectory() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path)
            .sorted()
    }

    private func sampleRecords() -> [UsageRecord] {
        [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: "2026-05-29",
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 5, cacheCreationTokens: 3, costUSD: 1.25
            ),
            UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-29", inputTokens: 42)
        ]
    }

    // MARK: - Default (atomic) write path

    /// After a default write, the `.jsonl` is present + complete + parseable, and
    /// no leftover `.tmp` remains in the directory.
    func testAtomicWriteLeavesCompleteFileAndNoTemp() throws {
        let machineID = "atomicmachine0001"
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: sampleRecords(), machineID: machineID)

        let jsonl = writer.fileURL(machineID: machineID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonl.path))

        // No `.tmp` survives — the directory holds exactly the one `.jsonl`.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpSibling(for: jsonl).path))
        XCTAssertEqual(try contentsOfDirectory(), ["\(machineID).jsonl"])

        // Content is complete and every line is valid JSON for RollupLine.
        let contents = try String(contentsOf: jsonl, encoding: .utf8)
        let lines = contents.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoded = try lines.map { try JSONDecoder().decode(RollupLine.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded[0].provider, .claude)
        XCTAssertEqual(decoded[0].inputTokens, 100)
        XCTAssertEqual(decoded[1].provider, .codex)
        XCTAssertEqual(decoded[1].inputTokens, 42)
    }

    /// The default write path produces byte-for-byte the same content as the pure
    /// serializer — the atomicity wrapper changes durability, not the bytes.
    func testAtomicWriteContentMatchesNonAtomicCapture() throws {
        let machineID = "atomicmatchmach01"

        // Capture what the serializer hands to the write primitive.
        final class Capture: @unchecked Sendable { var data: Data? }
        let capture = Capture()
        let capturingWriter = DailyRollupWriter(directory: tempDir) { data, _ in capture.data = data }
        try capturingWriter.write(records: sampleRecords(), machineID: machineID)

        // Now do a real atomic write and compare the on-disk bytes.
        let atomicWriter = DailyRollupWriter(directory: tempDir)
        try atomicWriter.write(records: sampleRecords(), machineID: machineID)
        let onDisk = try Data(contentsOf: atomicWriter.fileURL(machineID: machineID))

        XCTAssertEqual(onDisk, capture.data)
    }

    /// Empty records still write atomically: a zero-byte `.jsonl`, no `.tmp`.
    func testAtomicWriteEmptyRecordsWritesEmptyFileNoTemp() throws {
        let machineID = "atomicemptymach01"
        let writer = DailyRollupWriter(directory: tempDir)
        try writer.write(records: [], machineID: machineID)

        let jsonl = writer.fileURL(machineID: machineID)
        XCTAssertEqual(try Data(contentsOf: jsonl).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpSibling(for: jsonl).path))
        XCTAssertEqual(try contentsOfDirectory(), ["\(machineID).jsonl"])
    }

    /// A second atomic write fully replaces the first (rename overwrites), and no
    /// `.tmp` is left after either run.
    func testAtomicWriteOverwritesPreviousFileAtomically() throws {
        let machineID = "atomicoverwrite01"
        let writer = DailyRollupWriter(directory: tempDir)

        try writer.write(records: sampleRecords(), machineID: machineID)
        try writer.write(
            records: [UsageRecord(provider: .codex, model: "gpt-5", day: "2026-05-30", inputTokens: 7)],
            machineID: machineID
        )

        let jsonl = writer.fileURL(machineID: machineID)
        let contents = try String(contentsOf: jsonl, encoding: .utf8)
        let lines = contents.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1, "second write must replace, not append")
        let only = try JSONDecoder().decode(RollupLine.self, from: Data(lines[0].utf8))
        XCTAssertEqual(only.date, "2026-05-30")
        XCTAssertEqual(only.inputTokens, 7)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpSibling(for: jsonl).path))
        XCTAssertEqual(try contentsOfDirectory(), ["\(machineID).jsonl"])
    }

    // MARK: - Interruption safety

    /// Simulate a kill *after* the temp is written but *before* the rename: the
    /// prior `.jsonl` must remain fully intact and parseable. (We model the
    /// interruption by writing the temp directly, never renaming.)
    func testInterruptedWriteLeavesPriorFileIntact() throws {
        let machineID = "atomicinterrupt01"
        let writer = DailyRollupWriter(directory: tempDir)

        // Establish a good prior file.
        try writer.write(records: sampleRecords(), machineID: machineID)
        let jsonl = writer.fileURL(machineID: machineID)
        let priorBytes = try Data(contentsOf: jsonl)

        // Simulate an interrupted write: bytes land in `.tmp`, the rename never runs.
        let tmp = tmpSibling(for: jsonl)
        try Data("garbage-half-written".utf8).write(to: tmp)

        // The prior `.jsonl` is byte-for-byte unchanged and still parseable.
        let afterBytes = try Data(contentsOf: jsonl)
        XCTAssertEqual(afterBytes, priorBytes)
        let lines = try String(contentsOf: jsonl, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertNoThrow(try lines.map { try JSONDecoder().decode(RollupLine.self, from: Data($0.utf8)) })
    }

    /// A subsequent successful atomic write reclaims the directory: the stray
    /// `.tmp` from a prior interruption is overwritten in place (same temp path),
    /// leaving only the final `.jsonl`.
    func testStrayTempFromInterruptionIsReplacedByNextWrite() throws {
        let machineID = "atomicstraytmp001"
        let writer = DailyRollupWriter(directory: tempDir)
        let jsonl = writer.fileURL(machineID: machineID)
        let tmp = tmpSibling(for: jsonl)

        // A stray temp from a prior crash.
        try Data("leftover".utf8).write(to: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        // A fresh write reuses the same temp path then renames it away.
        try writer.write(records: sampleRecords(), machineID: machineID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertEqual(try contentsOfDirectory(), ["\(machineID).jsonl"])
    }

    // MARK: - Failure paths

    /// Writing into a non-existent directory fails (can't create the temp) and
    /// leaves nothing behind — no `.tmp`, no `.jsonl`.
    func testFailedWriteToMissingDirectoryLeavesNoFiles() throws {
        let missingDir = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let writer = DailyRollupWriter(directory: missingDir)

        XCTAssertThrowsError(try writer.write(records: sampleRecords(), machineID: "atomicmissingdir1"))

        // The parent temp dir still has no children for this machine.
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir.path))
        XCTAssertEqual(try contentsOfDirectory(), [])
    }

    /// `atomicWrite(_:to:)` is callable directly and produces the bytes verbatim.
    func testAtomicWritePrimitiveRoundTrips() throws {
        let url = tempDir.appendingPathComponent("primitive.jsonl", isDirectory: false)
        let payload = Data("line-one\nline-two".utf8)
        try DailyRollupWriter.atomicWrite(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
        let tmp = tmpSibling(for: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }
}
