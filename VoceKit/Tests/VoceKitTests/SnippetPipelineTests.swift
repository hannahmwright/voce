import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

private func finalize(
    transcript: String,
    snippets: [Snippet],
    structureMode: StructureMode = .paragraph
) async throws -> FinalizedTranscript {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: transcript) },
        cleanupEngine: RuleBasedCleanupEngine(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(
            globalProfile: StyleProfile(
                name: "Default",
                tone: .natural,
                structureMode: structureMode,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            )
        ),
        snippetService: SnippetService(snippets: snippets),
        voiceCommandService: VoiceCommandService(commands: VoiceCommand.builtIns)
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    return try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test("Multi-line snippet expansions keep their line breaks and wording")
func multiLineSnippetIsInsertedVerbatim() async throws {
    let expansion = "Best regards,\nHannah, um, Wright\nnew line Industries, period"
    let result = try await finalize(
        transcript: "um thanks for your help my sig",
        snippets: [Snippet(trigger: "my sig", expansion: expansion)]
    )

    #expect(result.cleanText == "Thanks for your help \(expansion)")
    #expect(result.rawText == "um thanks for your help my sig")
}

@Test("Snippets still expand alongside cleanup and voice commands")
func snippetExpandsWithCleanupAndVoiceCommands() async throws {
    let result = try await finalize(
        transcript: "um send it to addr question mark",
        snippets: [Snippet(trigger: "addr", expansion: "1 Main St")]
    )

    #expect(result.cleanText == "Send it to 1 Main St?")
}

@Test("Cleanup preserves line breaks while collapsing spaces")
func cleanupPreservesLineBreaks() {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Natural",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    let candidate = engine.buildCandidate(
        raw: RawTranscript(text: "Line one  um  here\nuh line   two\n\nLine three"),
        profile: profile,
        lexicon: PersonalLexicon(),
        rulePathID: "test"
    )

    #expect(candidate.text == "Line one here\nline two\n\nLine three")
}

@Test("Deduplicator preserves line breaks when collapsing repeats")
func deduplicatorPreservesLineBreaks() {
    let collapsed = ConsecutivePhraseDeduplicator.collapse(
        "Header line\nthe quick brown fox jumps the quick brown fox jumps\nFooter line"
    )
    let unchanged = ConsecutivePhraseDeduplicator.collapse("one two three four\nfive six seven eight")

    #expect(collapsed == "Header line\nthe quick brown fox jumps\nFooter line")
    #expect(unchanged == "one two three four\nfive six seven eight")
}
