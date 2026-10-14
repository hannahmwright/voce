import Foundation
import Testing
@testable import VoceKit

private func builtInService() -> VoiceCommandService {
    VoiceCommandService(commands: VoiceCommand.builtIns)
}

// MARK: - Ordinary prose must be unchanged

@Test(
    "Built-in voice commands leave ordinary prose unchanged",
    arguments: [
        "Please delete that file from the server.",
        "The trial period ended yesterday.",
        "There is not enough space on the disk.",
        "He had a colon procedure.",
        "We launched a new line of products.",
        "The grace period is thirty days.",
        "I need more space.",
        "Add a dash of salt to the soup.",
        "Can you delete that?",
        "I told him to scratch that idea.",
        "Don't forget to delete that.",
        "She won the hundred meter dash.",
        "The comment period closes Friday.",
        "Put a comma after the greeting.",
        "There is a big question mark over the budget.",
        "The colon is part of the digestive system.",
        "We waited for a long period.",
        "Lost in space.",
        "Start a new paragraph when the topic changes.",
        "Use a hyphen between the words.",
        "We need to scratch that from the list.",
        "The new line manager starts Monday.",
        "Leave some white space around the logo.",
        "It was a dark period in history.",
        "Office space is expensive here.",
        "I'll be gone for a period of two weeks.",
        "Please scratch that off your list.",
        "If you made a typo, just delete that.",
        "That was a difficult period.",
        "I love the Oxford comma.",
    ]
)
func voiceCommandsLeaveProseUnchanged(sentence: String) {
    #expect(builtInService().apply(to: sentence) == sentence)
}

// MARK: - Intended use still works

@Test("Spoken punctuation at the end and anywhere-commands still work")
func voiceCommandsSpokenPunctuation() {
    let service = builtInService()

    #expect(service.apply(to: "Hello comma how are you period") == "Hello, how are you.")
    #expect(service.apply(to: "How are you question mark") == "How are you?")
    #expect(service.apply(to: "Wait exclamation point") == "Wait!")
    #expect(service.apply(to: "Dear team colon") == "Dear team:")
    #expect(service.apply(to: "red semicolon blue") == "red; blue")
    #expect(service.apply(to: "and then ellipsis") == "and then\u{2026}")
}

@Test("Line and paragraph commands still work mid-utterance")
func voiceCommandsLineBreaks() {
    let service = builtInService()

    #expect(service.apply(to: "first line new line second line") == "first line\nsecond line")
    #expect(service.apply(to: "intro new paragraph body") == "intro\n\nbody")
    // Punctuation the recognizer puts after the command is dropped; punctuation
    // before it is kept (salutations: "Hi John,").
    #expect(service.apply(to: "first line new line, second line") == "first line\nsecond line")
    #expect(service.apply(to: "Hi John, new paragraph thanks for coming") == "Hi John,\n\nthanks for coming")
}

@Test("Ambiguous triggers fire before another command or when set off by punctuation")
func voiceCommandsAmbiguousTriggersWithContext() {
    let service = builtInService()

    #expect(service.apply(to: "end of sentence period new paragraph next one") == "end of sentence.\n\nnext one")
    #expect(service.apply(to: "Item one, period.") == "Item one.")
    #expect(service.apply(to: "The meeting is over. Period.") == "The meeting is over.")
    #expect(service.apply(to: "wait, dash, what") == "wait \u{2014} what")
}

@Test("Quote, paren and hyphen commands produce tight spacing")
func voiceCommandsBracketsAndHyphen() {
    let service = builtInService()

    #expect(service.apply(to: "He said open quote hello close quote") == "He said \u{201C}hello\u{201D}")
    #expect(service.apply(to: "see open paren below close paren") == "see (below)")
    #expect(service.apply(to: "a well hyphen known fact") == "a well-known fact")
}

@Test("Spoken punctuation absorbs punctuation the recognizer already added")
func voiceCommandsAbsorbRecognizerPunctuation() {
    let service = builtInService()

    #expect(service.apply(to: "Hello, comma, how are you, question mark.") == "Hello, how are you?")
}

// MARK: - Deletion

@Test("Scratch that deletes the previous sentence when it ends the utterance")
func voiceCommandsScratchThatAtEnd() {
    let service = builtInService()

    #expect(service.apply(to: "Keep this. Hello world scratch that") == "Keep this.")
    #expect(service.apply(to: "Hello world scratch that") == "")
    #expect(service.apply(to: "Keep this. Remove this. Scratch that.") == "Keep this.")
    #expect(service.apply(to: "Keep this. Remove this. Delete that.") == "Keep this.")
}

@Test("Scratch that as a stand-alone sentence mid-utterance deletes the sentence before it")
func voiceCommandsScratchThatStandAloneSentence() {
    let service = builtInService()

    #expect(service.apply(to: "Keep this. Remove this. Scratch that. Goodbye.") == "Keep this. Goodbye.")
}

@Test("Scratch that after a spoken sentence terminator deletes only the latest sentence")
func voiceCommandsScratchThatRespectsSpokenTerminators() {
    let service = builtInService()

    #expect(service.apply(to: "Keep this question mark remove this scratch that") == "Keep this?")
}

@Test("Scratch that uses consistent offsets with emoji and leading whitespace")
func voiceCommandsScratchThatUnicodeOffsets() {
    let service = builtInService()

    #expect(service.apply(to: "a\u{1F355}\u{1F355}. Hello world scratch that") == "a\u{1F355}\u{1F355}.")
    #expect(service.apply(to: "  Hello. Some words scratch that") == "Hello.")
    #expect(service.apply(to: "Caf\u{00E9} \u{1F355} ok. \u{1F355} more scratch that") == "Caf\u{00E9} \u{1F355} ok.")
}

// MARK: - Custom and disabled commands

@Test("Custom insert commands keep firing wherever the trigger appears")
func voiceCommandsCustomInsertFiresAnywhere() {
    let service = VoiceCommandService(commands: [
        VoiceCommand(trigger: "smiley", action: .insertText(":)")),
    ])

    #expect(service.apply(to: "great job smiley see you") == "great job :) see you")
}

@Test("Disabled built-ins do not fire")
func voiceCommandsDisabledBuiltInDoesNotFire() {
    let commands = VoiceCommand.builtIns.map { command -> VoiceCommand in
        var updated = command
        if command.trigger == "comma" { updated.isEnabled = false }
        return updated
    }
    let service = VoiceCommandService(commands: commands)

    #expect(service.apply(to: "Hello comma world") == "Hello comma world")
}

@Test("Text without triggers is returned untouched, including whitespace")
func voiceCommandsNoTriggerReturnsOriginal() {
    let text = "  Spacing  stays\nas is . "
    #expect(builtInService().apply(to: text) == text)
}

// MARK: - Built-in refresh

@Test("Merging built-ins refreshes definitions and keeps user choices and custom commands")
func voiceCommandMergingBuiltIns() {
    let storedCommaID = UUID()
    let custom = VoiceCommand(trigger: "undo that", action: .deletePrevious)
    let stored: [VoiceCommand] = [
        // Stale definition with the user's disabled choice.
        VoiceCommand(id: storedCommaID, trigger: "Comma", action: .insertText(" , "), isEnabled: false, isBuiltIn: true),
        // Built-in that no longer ships.
        VoiceCommand(trigger: "retired command", action: .insertText("x"), isBuiltIn: true),
        custom,
    ]

    let merged = VoiceCommand.mergingBuiltIns(into: stored)

    #expect(merged.count == VoiceCommand.builtIns.count + 1)
    #expect(merged.map(\.trigger).prefix(VoiceCommand.builtIns.count) == VoiceCommand.builtIns.map(\.trigger)[...])
    let comma = merged.first { $0.trigger == "comma" }
    #expect(comma?.id == storedCommaID)
    #expect(comma?.isEnabled == false)
    #expect(comma?.action == .insertText(","))
    #expect(merged.contains { $0.trigger == "retired command" } == false)
    #expect(merged.last == custom)
    #expect(VoiceCommand.mergingBuiltIns(into: merged) == merged)
}
