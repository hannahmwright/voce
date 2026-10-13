import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

private func finalize(
    transcript: String,
    snippets: [Snippet],
    structureMode: StructureMode = .natural,
    cleanupEngine: any CleanupEngine = RuleBasedCleanupEngine(),
    lexicon: [LexiconEntry] = []
) async throws -> FinalizedTranscript {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: transcript) },
        cleanupEngine: cleanupEngine,
        lexiconService: PersonalLexiconService(entries: lexicon),
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
        voiceCommandService: VoiceCommandService(commands: VoiceCommand.builtIns),
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    return try await coordinator.stopPressToTalk(sessionID: sessionID)
}

/// Simulates a cloud refiner that rewrites text and loses private-use characters.
private struct PlaceholderDroppingCleanupEngine: CleanupEngine {
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        var text = raw.text
        text.unicodeScalars.removeAll { (0xE000...0xF8FF).contains($0.value) }
        return CleanTranscript(text: "REFINED " + text)
    }
}

/// Simulates a cloud refiner that keeps placeholders but rewrites other words.
private struct PlaceholderKeepingCleanupEngine: CleanupEngine {
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        CleanTranscript(text: raw.text.replacingOccurrences(of: "um ", with: "").replacingOccurrences(of: "thx", with: "Thanks"))
    }
}

private let signature = Snippet(trigger: "sig", expansion: "Best,\nHannah")

@Test("Filler removal does not mangle a snippet trigger")
func fillerRemovalDoesNotMangleTrigger() async throws {
    let result = try await finalize(transcript: "um sig", snippets: [signature])

    #expect(result.cleanText == "Best,\nHannah")
}

@Test("Lexicon entries cannot rewrite a snippet trigger")
func lexiconDoesNotRewriteTrigger() async throws {
    let result = try await finalize(
        transcript: "thanks sig",
        snippets: [signature],
        lexicon: [LexiconEntry(term: "sig", preferred: "SIG", scope: .global)]
    )

    #expect(result.cleanText == "thanks Best,\nHannah")
}

@Test("Expansion at sentence start is capitalized")
func expansionAtSentenceStartIsCapitalized() async throws {
    let brb = Snippet(trigger: "brb", expansion: "be right back")

    let natural = try await finalize(transcript: "brb see you", snippets: [brb])
    let paragraph = try await finalize(transcript: "brb see you", snippets: [brb], structureMode: .paragraph)
    let midSentence = try await finalize(transcript: "ok brb see you", snippets: [brb])
    let email = try await finalize(
        transcript: "mail me at",
        snippets: [Snippet(trigger: "mail me at", expansion: "hannah@example.com")]
    )

    #expect(natural.cleanText == "Be right back see you")
    #expect(paragraph.cleanText == "Be right back see you")
    #expect(midSentence.cleanText == "ok be right back see you")
    #expect(email.cleanText == "hannah@example.com")
}

@Test("Multi-word triggers match across recognizer line breaks and extra spaces")
func multiWordTriggerMatchesAcrossWhitespace() async throws {
    let service = SnippetService(snippets: [Snippet(trigger: "my address", expansion: "1 Main St")])

    #expect(await service.apply(to: "send to my\n\naddress today", appContext: nil) == "send to 1 Main St today")
    #expect(await service.apply(to: "send to my   address", appContext: nil) == "send to 1 Main St")
}

@Test("Refined text that loses a placeholder is discarded for local cleanup")
func lostPlaceholderFallsBackToLocalCleanup() async throws {
    let result = try await finalize(
        transcript: "um thanks for the help sig",
        snippets: [signature],
        cleanupEngine: PlaceholderDroppingCleanupEngine()
    )

    #expect(result.cleanText == "thanks for the help Best,\nHannah")
    #expect(result.cleanupOutcome?.source == .localFallback)
}

@Test("Refined text that keeps placeholders is used and receives the expansion")
func keptPlaceholderUsesRefinedText() async throws {
    let result = try await finalize(
        transcript: "um thx sig",
        snippets: [signature],
        cleanupEngine: PlaceholderKeepingCleanupEngine()
    )

    #expect(result.cleanText == "Thanks Best,\nHannah")
    #expect(result.cleanupOutcome?.source == .localSuccess)
}

@Test("Placeholder integrity check requires each placeholder exactly once")
func placeholderIntegrityCheck() async {
    let service = SnippetService(snippets: [signature, Snippet(trigger: "brb", expansion: "be right back")])
    let protected = await service.protect("sig and brb", appContext: nil)
    let placeholders = Array(protected.expansions.keys)

    #expect(protected.expansions.count == 2)
    #expect(protected.text.contains("sig") == false)
    #expect(protected.placeholdersAreIntact(in: protected.text))
    #expect(protected.placeholdersAreIntact(in: "Rewritten: " + protected.text.uppercased()))
    #expect(protected.placeholdersAreIntact(in: protected.text + placeholders[0]) == false)
    #expect(protected.placeholdersAreIntact(in: protected.text.replacingOccurrences(of: placeholders[1], with: "")) == false)
    #expect(protected.restore(in: protected.text) == "Best,\nHannah and be right back")
}

@Test("Placeholders survive every local cleanup step and voice commands")
func placeholdersSurviveLocalProcessing() async throws {
    let service = SnippetService(snippets: [signature])
    let protected = await service.protect("um so, uh, sig comma period", appContext: nil)
    let engine = RuleBasedCleanupEngine()

    for structureMode in StructureMode.allCases {
        let cleaned = try await engine.cleanup(
            raw: RawTranscript(text: protected.text),
            profile: StyleProfile(name: "x", tone: .natural, structureMode: structureMode, fillerPolicy: .aggressive, commandPolicy: .transform),
            lexicon: PersonalLexicon(entries: [LexiconEntry(term: "1", preferred: "one", scope: .global)])
        )
        let commanded = VoiceCommandService(commands: VoiceCommand.builtIns).apply(to: cleaned.text)
        #expect(protected.placeholdersAreIntact(in: commanded), "structure mode \(structureMode)")
    }
}
