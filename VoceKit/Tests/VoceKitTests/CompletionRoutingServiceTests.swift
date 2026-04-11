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
        preferredAction: .aiWorkflow(id: AIWorkflow.askID),
        leadingPhraseSelectionEnabled: true,
        workflows: AIWorkflow.builtIns
    )

    #expect(routed.action == .aiWorkflow(id: AIWorkflow.askID))
    #expect(routed.inputText == "summarize this quarterly update")
    #expect(routed.selectedBy == .alternateFinishKey(workflowID: AIWorkflow.askID))
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

@Test("CompletionRoutingService still throws when trigger is followed only by punctuation")
func completionRoutingFailsWhenOnlyPunctuationFollowsTrigger() throws {
    let service = CompletionRoutingService()
    let transcript = FinalizedTranscript(
        rawText: "summarize this:",
        cleanText: "summarize this:",
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
