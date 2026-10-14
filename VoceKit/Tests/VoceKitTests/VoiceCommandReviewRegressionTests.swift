import Foundation
import Testing
@testable import VoceKit

private func service() -> VoiceCommandService {
    VoiceCommandService(commands: VoiceCommand.builtIns)
}

// MARK: - Ordinary sentence endings

@Test(
    "Commands fire after ordinary sentence endings",
    arguments: [
        ("I can't do that period", "I can't do that."),
        ("Thanks for that period", "Thanks for that."),
        ("Let me think about this period", "Let me think about this."),
        ("Count me in period", "Count me in."),
        ("Turn it on period", "Turn it on."),
        ("Who is it for period", "Who is it for."),
        ("The answer is no period", "The answer is no."),
        ("Did you call her question mark", "Did you call her?"),
        ("I saw her comma then I left", "I saw her, then I left"),
        ("I told him no comma not today", "I told him no, not today"),
        ("Say yes or no question mark", "Say yes or no?"),
        ("Let me think about that colon", "Let me think about that:"),
    ]
)
func voiceCommandsFireAfterOrdinaryEndings(input: String, expected: String) {
    #expect(service().apply(to: input) == expected)
}

@Test(
    "Scratch that after conjunctions and discourse words deletes",
    arguments: [
        ("Keep this. I'll be late so scratch that", "Keep this."),
        ("Keep this. Oh just scratch that", "Keep this."),
        ("Keep this. Hello world and scratch that", "Keep this."),
        ("Keep this. Send it then scratch that", "Keep this."),
        ("so scratch that", ""),
        ("Oh just scratch that", ""),
        ("Hello world and scratch that", ""),
    ]
)
func voiceCommandsScratchThatAfterConjunctions(input: String, expected: String) {
    #expect(service().apply(to: input) == expected)
}

@Test(
    "Noun uses at the end of an utterance stay unchanged",
    arguments: [
        "The trial period.",
        "Thirty days is the grace period.",
        "Check his colon.",
        "We ran out of disk space.",
        "She won the hundred meter dash.",
        "First copy the file, then delete that.",
        "Did she get her period?",
        "I'll scratch that.",
    ]
)
func voiceCommandsNounEndingsUnchanged(sentence: String) {
    #expect(service().apply(to: sentence) == sentence)
}

// MARK: - Consecutive commands

@Test(
    "Consecutive commands all apply",
    arguments: [
        ("Hello new line new line World", "Hello\n\nWorld"),
        ("Hello new paragraph new paragraph World", "Hello\n\n\n\nWorld"),
        ("Hello space new line World", "Hello\nWorld"),
        ("One dash period", "One \u{2014}."),
        ("wait dash dash ok", "wait \u{2014} \u{2014} ok"),
        ("x hyphen hyphen y", "x--y"),
        ("x space space y", "x y"),
        ("x tab key tab key y", "x\t\ty"),
        ("Hello comma comma world", "Hello,, world"),
        // Bare repeated commands (whitespace-only results trim to empty).
        ("dash dash", "\u{2014} \u{2014}"),
        ("hyphen hyphen", "--"),
        ("new paragraph new paragraph", ""),
        ("space space", ""),
        ("tab key tab key", ""),
    ]
)
func voiceCommandsConsecutive(input: String, expected: String) {
    #expect(service().apply(to: input) == expected)
}

// MARK: - Mid-utterance sentence breaks

@Test("Period and colon fire mid-utterance when the next word starts a sentence")
func voiceCommandsMidUtteranceSentenceBreaks() {
    let service = service()

    #expect(
        service.apply(to: "thanks for the note period I will send it tomorrow period")
            == "thanks for the note. I will send it tomorrow."
    )
    #expect(service.apply(to: "Dear team colon Please review") == "Dear team: Please review")
    #expect(service.apply(to: "The trial period ended yesterday.") == "The trial period ended yesterday.")
    #expect(service.apply(to: "He had a colon procedure.") == "He had a colon procedure.")
    #expect(
        service.apply(to: "During the Victorian period Charles Dickens wrote.")
            == "During the Victorian period Charles Dickens wrote."
    )
}
