import Foundation
import Testing
@testable import MimirCore

@Test("Recording archive keeps audio with its raw text and prunes the oldest")
func recordingArchiveKeepsPairsAndPrunes() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("mimir-archive-test-\(UUID().uuidString)")
    let archive = root.appendingPathComponent("Recordings")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let audio = root.appendingPathComponent("capture.wav")
    try Data([1, 2, 3]).write(to: audio)

    for index in 0..<3 {
        RecordingArchive.keep(
            audioAt: audio,
            rawText: "ditado \(index)",
            in: archive,
            now: Date(timeIntervalSince1970: Double(index) * 60),
            limit: 2
        )
    }

    let names = try fileManager.contentsOfDirectory(atPath: archive.path).sorted()
    #expect(names.count == 4)
    #expect(names.filter { $0.hasSuffix(".wav") }.count == 2)
    let texts = try names.filter { $0.hasSuffix(".txt") }
        .map { try String(contentsOf: archive.appendingPathComponent($0), encoding: .utf8) }
    #expect(texts == ["ditado 1", "ditado 2"])
    // O original não é movido: o controller ainda o usa como fallback.
    #expect(fileManager.fileExists(atPath: audio.path))
}
