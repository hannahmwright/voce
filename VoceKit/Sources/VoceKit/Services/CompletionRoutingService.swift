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

        for (workflow, phrase) in enabledWorkflows {
            if let remainderStart = leadingRemainderStartIndex(in: trimmedText, matching: phrase) {
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

            if let triggerStart = trailingTriggerStartIndex(in: trimmedText, matching: phrase) {
                let remaining = trimmedText[..<triggerStart]
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
        }

        return RoutedCompletion(
            action: .insert,
            inputText: finalizedTranscript.cleanText,
            selectedBy: .defaultBehavior
        )
    }

    private func leadingRemainderStartIndex(in text: String, matching phrase: String) -> String.Index? {
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
        guard isPhraseBoundary(nextCharacter) else {
            return nil
        }

        return phraseEnd
    }

    private func trailingTriggerStartIndex(in text: String, matching phrase: String) -> String.Index? {
        guard text.count >= phrase.count else { return nil }

        let whitespaceTrimmedEnd = text.endIndexAfterTrimmingTrailingCharacters(in: .whitespacesAndNewlines)
        if let triggerStart = trailingTriggerStartIndex(in: text, matching: phrase, endingAt: whitespaceTrimmedEnd) {
            return triggerStart
        }

        let punctuationTrimmedEnd = text[..<whitespaceTrimmedEnd]
            .endIndexAfterTrimmingTrailingCharacters(in: .punctuationCharacters)
        guard punctuationTrimmedEnd != whitespaceTrimmedEnd else {
            return nil
        }
        return trailingTriggerStartIndex(in: text, matching: phrase, endingAt: punctuationTrimmedEnd)
    }

    private func trailingTriggerStartIndex(
        in text: String,
        matching phrase: String,
        endingAt phraseEnd: String.Index
    ) -> String.Index? {
        guard phraseEnd >= text.startIndex else { return nil }
        let textBeforeEnd = text[..<phraseEnd]
        guard textBeforeEnd.count >= phrase.count else { return nil }

        let phraseStart = text.index(phraseEnd, offsetBy: -phrase.count)
        let matchedSuffix = text[phraseStart..<phraseEnd]

        guard matchedSuffix.caseInsensitiveCompare(phrase) == .orderedSame else {
            return nil
        }

        guard phraseStart > text.startIndex else {
            return phraseStart
        }

        let previousCharacter = text[text.index(before: phraseStart)]
        guard isPhraseBoundary(previousCharacter) else {
            return nil
        }

        return phraseStart
    }

    private func isPhraseBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character.isNewline || character.isPunctuation
    }
}

private extension StringProtocol {
    func endIndexAfterTrimmingTrailingCharacters(in characterSet: CharacterSet) -> Index {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous].unicodeScalars.allSatisfy({ characterSet.contains($0) }) else {
                break
            }
            end = previous
        }
        return end
    }
}
