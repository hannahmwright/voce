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

        // A dictation that is only a trigger ("Summarize.") has nothing to send
        // to the AI, so it is inserted as ordinary text rather than failing and
        // losing what the user said.
        for (workflow, phrase) in enabledWorkflows {
            // Built-in single-word triggers ("rewrite", "summarize") are common
            // verbs, so they only route when clearly used as a command: at the
            // start and followed by an explicit delimiter ("Rewrite: …",
            // "Summarize, …"). Multi-word and custom triggers keep the original
            // whitespace-delimited and trailing matching.
            let isAmbiguousTrigger = workflow.isBuiltIn && !phrase.contains(where: \.isWhitespace)

            if let remainderStart = leadingRemainderStartIndex(
                in: trimmedText,
                matching: phrase,
                requiresExplicitDelimiter: isAmbiguousTrigger
            ) {
                let remaining = trimmedText[remainderStart...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !remaining.isEmpty else { continue }

                return RoutedCompletion(
                    action: .aiWorkflow(id: workflow.id),
                    inputText: remaining,
                    selectedBy: .leadingPhrase(workflowID: workflow.id, matchedPhrase: phrase)
                )
            }

            // Trailing triggers: never for ambiguous single-word built-ins
            // ("I still need to summarize."), and not when the dictation is a
            // question ("Can you rewrite this?").
            if !isAmbiguousTrigger,
               !trimmedText.hasSuffix("?"),
               let triggerStart = trailingTriggerStartIndex(in: trimmedText, matching: phrase) {
                let remaining = trimmedText[..<triggerStart]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !remaining.isEmpty else { continue }

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

    /// Characters that make a leading single-word trigger an explicit command.
    private static let explicitTriggerDelimiters: Set<Character> = [",", ":", ";", ".", "\n", "\u{2014}", "\u{2013}", "-"]

    private func leadingRemainderStartIndex(
        in text: String,
        matching phrase: String,
        requiresExplicitDelimiter: Bool
    ) -> String.Index? {
        guard let phraseEnd = leadingRemainderStartIndex(in: text, matching: phrase) else { return nil }
        guard requiresExplicitDelimiter else { return phraseEnd }
        guard phraseEnd < text.endIndex else {
            // The whole dictation is the trigger; there is no content either way.
            return phraseEnd
        }
        // Allow spaces before the delimiter ("Rewrite : …" from some recognizers).
        let delimiter = text[phraseEnd...].first { $0 != " " && $0 != "\t" }
        guard let delimiter, Self.explicitTriggerDelimiters.contains(delimiter) else { return nil }
        return phraseEnd
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

        // "I wrote a new AI prompt" uses the trigger as a noun phrase.
        if previousCharacter.isWhitespace,
           let previousWord = WordTokenizer.words(in: String(text[..<phraseStart].suffix(32))).last,
           Self.trailingTriggerNounMarkers.contains(previousWord) {
            return nil
        }

        return phraseStart
    }

    private static let trailingTriggerNounMarkers: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "his", "her", "its", "this", "that",
        "new", "another", "every", "each", "good", "great", "better", "best",
    ]

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
