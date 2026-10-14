import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

private func temporaryFileURL(_ name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("persistence-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
}

private let validEntryJSON = """
{"id":"6F1C9B8E-4A57-4B4B-9C55-0B1A1E2D3C4F","createdAt":"2026-01-02T03:04:05Z","appBundleID":"com.apple.Notes","rawText":"raw one","cleanText":"Clean one","insertionStatus":"inserted"}
"""

private let secondValidEntryJSON = """
{"id":"7A2D0C9F-5B68-4C5C-8D66-1C2B2F3E4D50","createdAt":"2026-01-03T03:04:05Z","appBundleID":"com.apple.Mail","rawText":"raw two","cleanText":"Clean two","insertionStatus":"copiedOnly"}
"""

// MARK: - HistoryStore

@Test("Corrupt history file is preserved instead of being overwritten")
func historyStorePreservesCorruptFile() async throws {
    let url = try temporaryFileURL("transcript-history.json")
    let corrupt = Data("{ this is not json".utf8)
    try corrupt.write(to: url)

    let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
    #expect(await store.recent(limit: 10).isEmpty)

    try await store.append(entry: TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "new",
        cleanText: "New",
        audioURL: nil,
        insertionStatus: .inserted
    ))

    let backups = CorruptFilePreserver.preservedCopies(of: url)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == corrupt)
    #expect(backups[0].lastPathComponent.hasPrefix("transcript-history.corrupt-"))
    #expect(backups[0].pathExtension == "json")

    let reloaded = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
    #expect(await reloaded.recent(limit: 10).map(\.cleanText) == ["New"])
}

@Test("One bad history entry is skipped without losing the others")
func historyStoreSkipsOneBadEntry() async throws {
    let url = try temporaryFileURL("transcript-history.json")
    let badEntry = #"{"id":"not-a-uuid","createdAt":12,"rawText":5}"#
    let original = Data("[\(validEntryJSON),\(badEntry),\(secondValidEntryJSON)]".utf8)
    try original.write(to: url)

    let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
    let entries = await store.recent(limit: 10)

    #expect(entries.map(\.cleanText) == ["Clean one", "Clean two"])
    let backups = CorruptFilePreserver.preservedCopies(of: url)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == original)
}

@Test("Lossy history load writes repaired data so later launches add no more backups")
func historyStoreRepairsAfterLossyLoad() async throws {
    let url = try temporaryFileURL("transcript-history.json")
    let badEntry = #"{"id":"not-a-uuid","createdAt":12,"rawText":5}"#
    try Data("[\(validEntryJSON),\(badEntry)]".utf8).write(to: url)

    for _ in 0..<3 {
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        #expect(await store.recent(limit: 10).map(\.cleanText) == ["Clean one"])
    }

    #expect(CorruptFilePreserver.preservedCopies(of: url).count == 1)
    let rewritten = try String(contentsOf: url, encoding: .utf8)
    #expect(rewritten.contains("not-a-uuid") == false)
}

@Test("Lossy learning data load writes repaired data so later launches add no more backups")
func learningEngineRepairsAfterLossyLoad() async throws {
    let url = try temporaryFileURL("learning-data.json")
    let json = #"{"wordFrequencies":{"hello":4},"corrections":[{"rawWord":7}]}"#
    try Data(json.utf8).write(to: url)

    for _ in 0..<3 {
        let engine = LearningEngine(storageURL: url)
        #expect(await engine.frequency(of: "hello") == 4)
    }

    #expect(CorruptFilePreserver.preservedCopies(of: url).count == 1)
}

@Test("Preserving the same unchanged file twice keeps a single copy")
func corruptFilePreserverSkipsIdenticalCopies() throws {
    let url = try temporaryFileURL("preferences.json")
    try Data("{\"partial\":true}".utf8).write(to: url)

    let first = CorruptFilePreserver.preserve(fileAt: url, moving: false, now: Date(timeIntervalSince1970: 0))
    let second = CorruptFilePreserver.preserve(fileAt: url, moving: false, now: Date(timeIntervalSince1970: 60))
    try Data("{\"partial\":false}".utf8).write(to: url)
    let third = CorruptFilePreserver.preserve(fileAt: url, moving: false, now: Date(timeIntervalSince1970: 120))

    #expect(first != nil)
    #expect(second?.lastPathComponent == first?.lastPathComponent)
    #expect(third?.lastPathComponent != first?.lastPathComponent)
    #expect(CorruptFilePreserver.preservedCopies(of: url).count == 2)
}

@Test("Unknown enum raw values in history entries are tolerated")
func historyStoreToleratesUnknownEnumValues() async throws {
    let url = try temporaryFileURL("transcript-history.json")
    let futureEntry = """
    {"id":"8B3E1DA0-6C79-4D6D-9E77-2D3C3F4F5E61","createdAt":"2026-02-02T03:04:05Z","appBundleID":"com.apple.Notes","rawText":"raw","cleanText":"Clean","insertionStatus":"teleported","aiProvider":"futureProvider","someNewField":true}
    """
    try Data("[\(futureEntry)]".utf8).write(to: url)

    let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
    let entries = await store.recent(limit: 10)

    #expect(entries.count == 1)
    #expect(entries.first?.cleanText == "Clean")
    #expect(entries.first?.insertionStatus == .copiedOnly)
    #expect(entries.first?.aiProvider == nil)
}

@Test("Valid history files load without creating backups")
func historyStoreValidFileCreatesNoBackup() async throws {
    let url = try temporaryFileURL("transcript-history.json")
    try Data("[\(validEntryJSON),\(secondValidEntryJSON)]".utf8).write(to: url)

    let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
    let entries = await store.recent(limit: 10)

    #expect(entries.count == 2)
    #expect(entries.first?.insertionStatus == .inserted)
    #expect(CorruptFilePreserver.preservedCopies(of: url).isEmpty)
}

@Test("TranscriptEntry round-trips through encoding")
func transcriptEntryRoundTrips() throws {
    let entry = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "raw",
        sourceText: "source",
        cleanText: "clean",
        audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
        insertionStatus: .failed,
        processingNote: "note",
        completionAction: "insert",
        aiWorkflowName: "Rewrite",
        aiProvider: .appleFoundationModels
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))

    #expect(decoded.id == entry.id)
    #expect(decoded.sourceText == "source")
    #expect(decoded.insertionStatus == .failed)
    #expect(decoded.aiProvider == .appleFoundationModels)
    #expect(decoded.audioURL == entry.audioURL)
}

// MARK: - LearningEngine

@Test("Corrupt learning data file is preserved and not overwritten")
func learningEnginePreservesCorruptFile() async throws {
    let url = try temporaryFileURL("learning-data.json")
    let corrupt = Data("[1, 2, 3".utf8)
    try corrupt.write(to: url)

    let engine = LearningEngine(storageURL: url)
    await engine.observeSession(rawText: "hello world", cleanText: "hello world", removedFillers: [], appBundleID: "a")
    await engine.save()

    let backups = CorruptFilePreserver.preservedCopies(of: url)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backups[0]) == corrupt)
    #expect(await LearningEngine(storageURL: url).frequency(of: "hello") == 1)
}

@Test("Learning data tolerates missing sections and skips bad corrections")
func learningDataLenientDecoding() async throws {
    let url = try temporaryFileURL("learning-data.json")
    let json = """
    {"wordFrequencies":{"hello":4},"corrections":[{"id":"9C4F2EB1-7D8A-4E7E-8F88-3E4D4A5B6C72","rawWord":"teh","correctedWord":"the","count":2,"lastSeen":0,"promoted":false},{"rawWord":7}]}
    """
    try Data(json.utf8).write(to: url)

    let engine = LearningEngine(storageURL: url)

    #expect(await engine.frequency(of: "hello") == 4)
    #expect(await engine.corrections().map(\.rawWord) == ["teh"])
    #expect(CorruptFilePreserver.preservedCopies(of: url).count == 1)
}

// MARK: - Latest-wins saves

@Test("Latest-wins sequencer drops snapshots older than one already written")
func latestWinsSequencerDropsStaleSnapshots() {
    let sequencer = LatestWinsSequencer()
    let first = sequencer.nextSequence()
    let second = sequencer.nextSequence()
    let third = sequencer.nextSequence()

    // Writes arrive out of order: second, first, third.
    #expect(sequencer.claimWrite(second))
    #expect(sequencer.claimWrite(first) == false)
    #expect(sequencer.claimWrite(third))
    #expect(sequencer.claimWrite(third) == false)
}

@Test("Latest-wins sequencer keeps the newest snapshot under concurrent writers")
func latestWinsSequencerConcurrentWriters() async {
    actor File {
        var contents: UInt64 = 0
        let sequencer: LatestWinsSequencer
        init(sequencer: LatestWinsSequencer) { self.sequencer = sequencer }
        func write(_ value: UInt64) {
            guard sequencer.claimWrite(value) else { return }
            contents = value
        }
    }

    let sequencer = LatestWinsSequencer()
    let file = File(sequencer: sequencer)
    let sequences = (0..<200).map { _ in sequencer.nextSequence() }

    await withTaskGroup(of: Void.self) { group in
        for sequence in sequences.shuffled() {
            group.addTask { await file.write(sequence) }
        }
    }

    #expect(await file.contents == sequences.last)
}

// MARK: - Lenient model decoding

@Test("Style profiles with unknown option values decode with defaults")
func styleProfileUnknownValuesFallBack() throws {
    let json = #"{"name":"Custom","tone":"sarcastic","structureMode":"paragraph","fillerPolicy":"extreme","commandPolicy":"transform"}"#

    let profile = try JSONDecoder().decode(StyleProfile.self, from: Data(json.utf8))

    #expect(profile.name == "Custom")
    #expect(profile.tone == .natural)
    #expect(profile.structureMode == .paragraph)
    #expect(profile.fillerPolicy == .balanced)
}

@Test("Lossy arrays skip undecodable elements and report them")
func lossyArraySkipsBadElements() throws {
    let json = #"[{"term":"a","preferred":"A","scope":{"global":{}}},{"term":3},{"term":"b","preferred":"B","scope":{"global":{}}}]"#
    let decoder = JSONDecoder()
    let report = LossyDecodingReport()
    decoder.attach(report)

    let decoded = try decoder.decode(LossyDecodableArray<LexiconEntry>.self, from: Data(json.utf8))

    #expect(decoded.elements.map(\.term) == ["a", "b"])
    #expect(report.skippedValueCount == 1)
}

@Test("AI workflows with an unknown hotkey format keep their identity")
func aiWorkflowLenientDecoding() throws {
    let json = """
    {"id":"87E578D8-2BEC-4CFD-9D55-01765A8D5759","name":"Rewrite","kind":"rewrite","leadingPhrases":["rewrite this"],"handsFreeFinishHotkey":{"futureKind":{"x":1}},"isEnabled":false}
    """

    let workflow = try JSONDecoder().decode(AIWorkflow.self, from: Data(json.utf8))

    #expect(workflow.id == AIWorkflow.rewriteID)
    #expect(workflow.leadingPhrases == ["rewrite this"])
    #expect(workflow.handsFreeFinishHotkey == nil)
    #expect(workflow.isEnabled == false)
    #expect(workflow.isBuiltIn == false)
}
