import Foundation
import Testing
import VoceKitTestSupport
@testable import VoceKit

private func service() -> VoiceCommandService {
    VoiceCommandService(commands: VoiceCommand.builtIns)
}

@Test(
    "Period and colon fire at the end, before uncased scripts and after salutations",
    arguments: [
        // Attached recognizer punctuation fires unless a modifier precedes.
        ("Call me period. Thanks period.", "Call me. Thanks."),
        ("I'm done period, see you", "I'm done, see you"),
        // When the trigger fires, attached ?/! replace the period.
        ("Done period?", "Done?"),
        ("Call me period!", "Call me!"),
        ("Done period? Really", "Done period? Really"),
        ("Call me period! Now", "Call me period! Now"),
        ("我们明天见 period 谢谢", "我们明天见. 谢谢"),
        ("שלום period מה שלומך", "שלום. מה שלומך"),
        ("Dear team colon please review", "Dear team: please review"),
        ("Hi all colon quick update", "Hi all: quick update"),
    ]
)
func periodColonFireWithRecognizerContext(input: String, expected: String) {
    #expect(service().apply(to: input) == expected)
}

@Test(
    "Prose with attached punctuation or lowercase continuation stays unchanged",
    arguments: [
        "The trial period, which ended Friday, was fine.",
        "It was a long period. Then we left.",
        "He had a colon procedure.",
        "Check his colon, then call me.",
        "The grace period ended yesterday.",
        "Each period, the teacher takes attendance.",
        "The Jurassic period, which lasted millions of years, ended.",
        "During the Edo period, Japan was isolated.",
        "In fifth period, I have math.",
        "My favorite period, honestly, is lunch.",
        "That was a great period. We grew.",
    ]
)
func proseWithPunctuationUnchanged(sentence: String) {
    #expect(service().apply(to: sentence) == sentence)
}

private func finalize(transcript: String, snippets: [Snippet]) async throws -> FinalizedTranscript {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: transcript) },
        cleanupEngine: RuleBasedCleanupEngine(),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(
            globalProfile: StyleProfile(name: "Natural", tone: .natural, structureMode: .natural, fillerPolicy: .balanced, commandPolicy: .transform)
        ),
        snippetService: SnippetService(snippets: snippets),
        voiceCommandService: VoiceCommandService(commands: VoiceCommand.builtIns)
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    return try await coordinator.stopPressToTalk(sessionID: sessionID)
}

@Test(
    "Period and colon fire before a snippet",
    arguments: [
        ("thanks period sig", "thanks. Best,\nHannah"),
        ("see you period brb", "see you. be right back"),
        ("thanks colon my address", "thanks: 1 Main St"),
    ]
)
func periodColonFireBeforeSnippet(input: String, expected: String) async throws {
    let result = try await finalize(transcript: input, snippets: [
        Snippet(trigger: "sig", expansion: "Best,\nHannah"),
        Snippet(trigger: "brb", expansion: "be right back"),
        Snippet(trigger: "my address", expansion: "1 Main St"),
    ])

    #expect(result.cleanText == expected)
}
