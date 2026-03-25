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
            case .insert, .insertAndSubmit:
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
            guard lowercasedText == loweredPhrase || lowercasedText.hasPrefix("\(loweredPhrase) ") else {
                continue
            }

            let startIndex = trimmedText.index(trimmedText.startIndex, offsetBy: phrase.count)
            let remaining = trimmedText[startIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
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
}
