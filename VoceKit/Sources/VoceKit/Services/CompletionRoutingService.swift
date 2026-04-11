import Foundation

public struct CompletionRoutingService: Sendable {
    public init() {}

    public func route(
        finalizedTranscript: FinalizedTranscript,
        preferredAction: CompletionAction?,
        leadingPhraseSelectionEnabled: Bool,
        workflows: [AIWorkflow]
    ) throws -> RoutedCompletion {
        if let preferredAction {
            switch preferredAction {
            case .aiWorkflow(let workflowID):
                guard workflows.contains(where: { $0.id == workflowID }) else {
                    throw CompletionRoutingError.workflowNotFound(workflowID)
                }
                return RoutedCompletion(
                    action: preferredAction,
                    inputText: finalizedTranscript.cleanText,
                    selectedBy: .alternateFinishKey(workflowID: workflowID)
                )
            case .insert, .copyToClipboard, .insertAndSubmit:
                return RoutedCompletion(
                    action: preferredAction,
                    inputText: finalizedTranscript.cleanText,
                    selectedBy: .defaultBehavior
                )
            }
        }

        guard leadingPhraseSelectionEnabled else {
            return RoutedCompletion(
                action: .insert,
                inputText: finalizedTranscript.cleanText,
                selectedBy: .defaultBehavior
            )
        }

        let enabledWorkflows = workflows
            .filter(\.isEnabled)
            .flatMap { workflow in
                workflow.leadingPhrases.map { phrase in
                    (workflow, phrase.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }

        let trimmedText = finalizedTranscript.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedText = trimmedText.lowercased()

        for (workflow, phrase) in enabledWorkflows {
            let loweredPhrase = phrase.lowercased()
            guard
                lowercasedText == loweredPhrase
                    || lowercasedText.hasPrefix(loweredPhrase),
                let remainderStart = remainderStartIndex(in: trimmedText, matching: phrase)
            else {
                continue
            }

            let remaining = trimmedText[remainderStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !remaining.isEmpty else {
                throw CompletionRoutingError.noContentAfterTrigger(phrase)
            }

            return RoutedCompletion(
                action: .aiWorkflow(id: workflow.id),
                inputText: remaining,
                selectedBy: .leadingPhrase(workflowID: workflow.id, matchedPhrase: phrase)
            )
        }

        return RoutedCompletion(
            action: .insert,
            inputText: finalizedTranscript.cleanText,
            selectedBy: .defaultBehavior
        )
    }

    private func remainderStartIndex(in text: String, matching phrase: String) -> String.Index? {
        guard text.count >= phrase.count else { return nil }

        let phraseEnd = text.index(text.startIndex, offsetBy: phrase.count)
        let matchedPrefix = text[..<phraseEnd]

        guard matchedPrefix.caseInsensitiveCompare(phrase) == .orderedSame else {
            return nil
        }

        guard phraseEnd < text.endIndex else {
            return phraseEnd
        }

        let nextCharacter = text[phraseEnd]
        guard nextCharacter.isWhitespace || nextCharacter.isNewline || nextCharacter.isPunctuation else {
            return nil
        }

        return phraseEnd
    }
}
