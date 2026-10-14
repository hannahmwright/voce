import Foundation
import Testing
@testable import VoceKit

@Test("CompletionRoutingService selects leading AI phrases and strips them")
func completionRoutingSelectsLeadingPhrase() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "rewrite this make this tighter",
        cleanText: "rewrite this make this tighter",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.rewriteID))
    #expect(routed.inputText == "make this tighter")
    #expect(routed.selectedBy == .leadingPhrase(workflowID: AIWorkflow.rewriteID, matchedPhrase: "rewrite this"))
}

@Test("CompletionRoutingService favors explicit AI finish key selection")
func completionRoutingPrefersExplicitAIAction() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "summarize this quarterly update",
        cleanText: "summarize this quarterly update",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: .aiWorkflow(id: AIWorkflow.aiPromptID),
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.aiPromptID))
    #expect(routed.inputText == "summarize this quarterly update")
    #expect(routed.selectedBy == .alternateFinishKey(workflowID: AIWorkflow.aiPromptID))
}

@Test("CompletionRoutingService throws when only an AI trigger phrase is present")
func completionRoutingFailsOnEmptyInput() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "summarize this",
        cleanText: "summarize this",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    #expect(throws: CompletionRoutingError.noContentAfterTrigger("summarize this")) {
        try service.route(
            finalizedTranscript: transcript,
            preferredAction: nil,
            leadingPhraseSelectionEnabled: true,
            workflows: AIWorkflow.builtIns
        )
    }
}

@Test("CompletionRoutingService accepts punctuation after an AI trigger phrase")
func completionRoutingAcceptsPunctuationAfterTrigger() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "rewrite this, make this tighter",
        cleanText: "rewrite this, make this tighter",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.rewriteID))
    #expect(routed.inputText == "make this tighter")
}

@Test("CompletionRoutingService accepts newlines after an AI trigger phrase")
func completionRoutingAcceptsNewlineAfterTrigger() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "summarize this\nquarterly update",
        cleanText: "summarize this\nquarterly update",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.summarizeID))
    #expect(routed.inputText == "quarterly update")
}

@Test("CompletionRoutingService selects delimited trailing AI phrases and strips them")
func completionRoutingSelectsTrailingPhrase() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "make this tighter - rewrite this",
        cleanText: "make this tighter - rewrite this",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.rewriteID))
    #expect(routed.inputText == "make this tighter")
    #expect(routed.selectedBy == .leadingPhrase(workflowID: AIWorkflow.rewriteID, matchedPhrase: "rewrite this"))
}

@Test("CompletionRoutingService accepts punctuation around trailing AI trigger phrases")
func completionRoutingAcceptsPunctuationAroundTrailingTrigger() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "make this tighter, rewrite this.",
        cleanText: "make this tighter, rewrite this.",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.rewriteID))
    #expect(routed.inputText == "make this tighter")
}

@Test("CompletionRoutingService ignores trailing AI phrases inside larger words")
func completionRoutingIgnoresTrailingPhraseWithoutBoundary() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "make this tighter prerewrite",
        cleanText: "make this tighter prerewrite",
        appContext: .unknown,
        sourceSessionID: UUID()
    )

    let routed = try service.route(
        finalizedTranscript: transcript,
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .insert)
    #expect(routed.inputText == "make this tighter prerewrite")
}

@Test("CompletionRoutingService still throws when trigger is followed only by punctuation")
func completionRoutingFailsWhenOnlyPunctuationFollowsTrigger() throws {
    let service = CompletionRoutingService()

    for (text, phrase) in [("summarize this:", "summarize this"), ("Summarize.", "summarize"), ("Rewrite", "rewrite")] {
        let transcript = FinalizedTranscript(
            rawText: text,
            cleanText: text,
            appContext: .unknown,
            sourceSessionID: UUID()
        )

        #expect(throws: CompletionRoutingError.noContentAfterTrigger(phrase)) {
            try service.route(
                finalizedTranscript: transcript,
                preferredAction: nil,
                leadingPhraseSelectionEnabled: true,
                workflows: AIWorkflow.builtIns
            )
        }
    }
}

private func routeBuiltIns(_ text: String) throws -> RoutedCompletion {
    try CompletionRoutingService().route(
        finalizedTranscript: FinalizedTranscript(
            rawText: text,
            cleanText: text,
            appContext: .unknown,
            sourceSessionID: UUID()
        ),
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )
}

@Test(
    "CompletionRoutingService does not route ordinary dictation that mentions a trigger verb",
    arguments: [
        "Rewrite the intro section before Friday.",
        "I still need to summarize.",
        "Can you rewrite?",
        "Can you rewrite this?",
        "Summarize the findings in the doc when you can.",
        "I wrote a new AI prompt",
        "We should rewrite the onboarding flow, then summarize the results.",
        "I need to rewrite this",
        "Who will summarize this",
        "make this tighter rewrite this",
        "Who will summarize this?",
    ]
)
func completionRoutingIgnoresOrdinaryDictation(text: String) throws {
    let routed = try routeBuiltIns(text)

    #expect(routed.action == .insert)
    #expect(routed.inputText == text)
}

@Test("CompletionRoutingService routes single-word built-in triggers with an explicit delimiter")
func completionRoutingSingleWordTriggerWithDelimiter() throws {
    let colon = try routeBuiltIns("Rewrite: we shipped the release late because of QA.")
    let comma = try routeBuiltIns("Summarize, the meeting covered hiring and budget.")
    let newline = try routeBuiltIns("summarize\nthe meeting covered hiring")

    #expect(colon.action == .aiWorkflow(id: AIWorkflow.rewriteID))
    #expect(colon.inputText == "we shipped the release late because of QA")
    #expect(comma.action == .aiWorkflow(id: AIWorkflow.summarizeID))
    #expect(comma.inputText == "the meeting covered hiring and budget")
    #expect(newline.action == .aiWorkflow(id: AIWorkflow.summarizeID))
}

@Test("CompletionRoutingService keeps whitespace-delimited and trailing matching for custom single-word triggers")
func completionRoutingCustomSingleWordTrigger() throws {
    let custom = AIWorkflow.makeCustomPrompt(name: "Translate", triggerPhrase: "translate", promptTemplate: "Translate: {{input}}")
    let service = CompletionRoutingService()

    let leading = try service.route(
        finalizedTranscript: FinalizedTranscript(rawText: "", cleanText: "translate good morning everyone", appContext: .unknown, sourceSessionID: UUID()),
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: [custom]
    )
    let trailing = try service.route(
        finalizedTranscript: FinalizedTranscript(rawText: "", cleanText: "good morning everyone translate", appContext: .unknown, sourceSessionID: UUID()),
        preferredAction: nil,
        leadingPhraseSelectionEnabled: true,
        workflows: [custom]
    )

    #expect(leading.action == .aiWorkflow(id: custom.id))
    #expect(leading.inputText == "good morning everyone")
    #expect(trailing.action == .aiWorkflow(id: custom.id))
    #expect(trailing.inputText == "good morning everyone")
}
