import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

private func finalize(
    transcript: String,
    snippets: [Snippet],
    structureMode: StructureMode = .natural,
    cleanupEngine: any CleanupEngine = RuleBasedCleanupEngine(),
    lexicon: [LexiconEntry] = [],
    appContext: AppContext = .unknown
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

    let sessionID = try await coordinator.startPressToTalk(appContext: appContext)
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

/// Simulates a cloud refiner that duplicates the text (and so each placeholder).
private struct PlaceholderDuplicatingCleanupEngine: CleanupEngine {
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        CleanTranscript(text: "REFINED " + raw.text + " " + raw.text)
    }
}

/// Records whether it was called.
private actor CallRecorder {
    var calls = 0
    func record() { calls += 1 }
}

private struct RecordingCleanupEngine: CleanupEngine {
    let recorder: CallRecorder
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        await recorder.record()
        return CleanTranscript(text: "REFINED " + raw.text)
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

@Test("Expansions are inserted verbatim except at the very start of a capitalizing profile")
func expansionsAreVerbatimExceptAtTextStart() async throws {
    let brb = Snippet(trigger: "brb", expansion: "be right back")
    let ty = Snippet(trigger: "ty", expansion: "thank you")
    let terminal = AppContext(bundleIdentifier: "com.apple.Terminal", appName: "Terminal")

    let paragraph = try await finalize(transcript: "brb see you", snippets: [brb], structureMode: .paragraph)
    let natural = try await finalize(transcript: "brb see you", snippets: [brb], structureMode: .natural)
    let gitStatus = try await finalize(
        transcript: "gs",
        snippets: [Snippet(trigger: "gs", expansion: "git status")],
        structureMode: .paragraph,
        appContext: terminal
    )
    let email = try await finalize(
        transcript: "mail me at",
        snippets: [Snippet(trigger: "mail me at", expansion: "hannah@example.com")],
        structureMode: .paragraph
    )

    #expect(paragraph.cleanText == "Be right back see you")
    #expect(natural.cleanText == "be right back see you")
    #expect(gitStatus.cleanText == "git status")
    #expect(email.cleanText == "hannah@example.com")

    for (input, expected) in [
        ("Mr. brb", "Mr. be right back"),
        ("e.g. brb", "E.g. be right back"),
        ("approx. ty", "Approx. thank you"),
        ("I use version 2. ty", "I use version 2. thank you"),
        ("wait... brb", "Wait... be right back"),
        ("ok brb see you", "Ok be right back see you"),
    ] {
        let result = try await finalize(transcript: input, snippets: [brb, ty], structureMode: .paragraph)
        #expect(result.cleanText == expected, "\(input)")
    }
}

@Test("Raw text keeps snippet expansions verbatim for history copy")
func rawTextKeepsExpansions() async throws {
    let result = try await finalize(transcript: "um thanks sig", snippets: [signature])

    #expect(result.rawText == "um thanks Best,\nHannah")
}

@Test("A dictation that is only a snippet trigger skips the primary cleanup")
func onlyTriggerSkipsPrimaryCleanup() async throws {
    let recorder = CallRecorder()
    let result = try await finalize(
        transcript: "sig",
        snippets: [signature],
        cleanupEngine: RecordingCleanupEngine(recorder: recorder)
    )

    #expect(result.cleanText == "Best,\nHannah")
    #expect(await recorder.calls == 0)
}

@Test("Multi-word triggers match across recognizer line breaks and extra spaces")
func multiWordTriggerMatchesAcrossWhitespace() async throws {
    let service = SnippetService(snippets: [Snippet(trigger: "my address", expansion: "1 Main St")])

    #expect(await service.apply(to: "send to my\n\naddress today", appContext: nil) == "send to 1 Main St today")
    #expect(await service.apply(to: "send to my   address", appContext: nil) == "send to 1 Main St")
}

@Test("Refined text that duplicates a placeholder is discarded for local cleanup without an outage warning")
func duplicatedPlaceholderFallsBackToLocalCleanup() async throws {
    let result = try await finalize(
        transcript: "um thanks for the help sig",
        snippets: [signature],
        cleanupEngine: PlaceholderDuplicatingCleanupEngine()
    )

    #expect(result.cleanText == "thanks for the help Best,\nHannah")
    #expect(result.cleanupOutcome?.source == .localFallback)
    #expect(result.cleanupOutcome?.warning == nil)
}

/// Simulates a refiner resolving a self-correction: drops the first placeholder only.
private struct FirstPlaceholderDroppingCleanupEngine: CleanupEngine {
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        var scalars = Array(raw.text.unicodeScalars)
        if let start = scalars.firstIndex(of: "\u{E000}"),
           let end = scalars[start...].firstIndex(of: "\u{E001}") {
            scalars.removeSubrange(start...end)
        }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return CleanTranscript(text: "REFINED " + text)
    }
}

@Test("Refined text that drops some placeholders (self-correction) is accepted")
func droppedPlaceholderIsAccepted() async throws {
    let result = try await finalize(
        transcript: "send it to my address, no actually my email, thanks sig",
        snippets: [Snippet(trigger: "my address", expansion: "1 Main St"), signature],
        cleanupEngine: FirstPlaceholderDroppingCleanupEngine()
    )

    #expect(result.cleanText == "REFINED send it to , no actually my email, thanks Best,\nHannah")
    #expect(result.cleanupOutcome?.source == .localSuccess)
}

@Test("Refined text that drops every placeholder falls back to local cleanup without a warning")
func allPlaceholdersDroppedFallsBack() async throws {
    let result = try await finalize(
        transcript: "send it to my address, no actually my email",
        snippets: [Snippet(trigger: "my address", expansion: "1 Main St")],
        cleanupEngine: PlaceholderDroppingCleanupEngine()
    )

    #expect(result.cleanText == "send it to 1 Main St, no actually my email")
    #expect(result.cleanupOutcome?.source == .localFallback)
    #expect(result.cleanupOutcome?.warning == nil)
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
    let placeholders = protected.placeholders

    #expect(protected.expansions.count == 2)
    #expect(protected.text.contains("sig") == false)
    #expect(protected.placeholdersAreIntact(in: protected.text))
    #expect(protected.placeholdersAreIntact(in: "Rewritten: " + protected.text.uppercased()))
    #expect(protected.placeholdersAreIntact(in: protected.text + placeholders[0]) == false)
    // Dropping a placeholder is fine while another survives; it simply isn't restored.
    #expect(protected.placeholdersAreIntact(in: protected.text.replacingOccurrences(of: placeholders[1], with: "")))
    // Losing every placeholder is a failure.
    #expect(protected.placeholdersAreIntact(in: "and") == false)
    // Unknown or altered placeholders are rejected.
    #expect(protected.placeholdersAreIntact(in: protected.text + SnippetProtectedText.placeholder(index: 7)) == false)
    #expect(protected.placeholdersAreIntact(in: protected.text + "\u{E000}x") == false)
    #expect(protected.restore(in: protected.text) == "Best,\nHannah and be right back")
    // Deterministic, position-ordered restoration even when ids are out of order.
    let swapped = placeholders[1] + " then " + placeholders[0]
    #expect(protected.restore(in: swapped) == "be right back then Best,\nHannah")
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
