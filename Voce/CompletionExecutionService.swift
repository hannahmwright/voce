import Foundation
import VoceKit

struct CompletionExecutionOutcome {
    var insertResult: InsertResult
    var finalText: String
    var sourceText: String?
    var action: CompletionAction
    var aiWorkflowName: String?
    var aiProvider: AIProvider?
    var submitWarning: String?
    var dictationPolishingApplied: Bool = false
    var dictationPolishingSkippedReason: String?
}

@MainActor
struct CompletionExecutionService {
    let insertionService: any InsertionServiceProtocol
    let clipboardService: any ClipboardService
    let aiGenerationService: AppleFoundationModelsService

    func execute(
        routedCompletion: RoutedCompletion,
        finalizedTranscript: FinalizedTranscript,
        workflows: [AIWorkflow],
        dictationPolishingEnabled: Bool = false
    ) async throws -> CompletionExecutionOutcome {
        switch routedCompletion.action {
        case .insert:
            let polished = await polishedDictationTextIfNeeded(
                finalizedTranscript.cleanText,
                enabled: dictationPolishingEnabled
            )
            var result = await insertionService.insert(
                text: polished.text,
                target: finalizedTranscript.appContext
            )
            result.cleanupOutcome = finalizedTranscript.cleanupOutcome
            return CompletionExecutionOutcome(
                insertResult: result,
                finalText: polished.text,
                sourceText: polished.sourceText,
                action: .insert,
                aiWorkflowName: nil,
                aiProvider: nil,
                submitWarning: nil,
                dictationPolishingApplied: polished.applied,
                dictationPolishingSkippedReason: polished.skippedReason
            )

        case .copyToClipboard:
            let polished = await polishedDictationTextIfNeeded(
                finalizedTranscript.cleanText,
                enabled: dictationPolishingEnabled
            )
            do {
                try await clipboardService.setString(polished.text)
                var result = InsertResult(
                    status: .copiedOnly,
                    method: .clipboardPaste,
                    insertedText: polished.text
                )
                result.cleanupOutcome = finalizedTranscript.cleanupOutcome
                return CompletionExecutionOutcome(
                    insertResult: result,
                    finalText: polished.text,
                    sourceText: polished.sourceText,
                    action: .copyToClipboard,
                    aiWorkflowName: nil,
                    aiProvider: nil,
                    submitWarning: nil,
                    dictationPolishingApplied: polished.applied,
                    dictationPolishingSkippedReason: polished.skippedReason
                )
            } catch {
                var result = InsertResult(
                    status: .failed,
                    method: .none,
                    insertedText: polished.text,
                    errorMessage: error.localizedDescription
                )
                result.cleanupOutcome = finalizedTranscript.cleanupOutcome
                return CompletionExecutionOutcome(
                    insertResult: result,
                    finalText: polished.text,
                    sourceText: polished.sourceText,
                    action: .copyToClipboard,
                    aiWorkflowName: nil,
                    aiProvider: nil,
                    submitWarning: nil,
                    dictationPolishingApplied: polished.applied,
                    dictationPolishingSkippedReason: polished.skippedReason
                )
            }

        case .insertAndSubmit:
            let polished = await polishedDictationTextIfNeeded(
                finalizedTranscript.cleanText,
                enabled: dictationPolishingEnabled
            )
            var result = await insertionService.insert(
                text: polished.text,
                target: finalizedTranscript.appContext
            )
            result.cleanupOutcome = finalizedTranscript.cleanupOutcome
            var submitWarning: String?
            if result.status == .inserted {
                let submitOutcome = await MacPasteHelper.activateAndPressReturn(target: finalizedTranscript.appContext)
                if case .skipped(let reason) = submitOutcome {
                    submitWarning = reason
                }
            }
            return CompletionExecutionOutcome(
                insertResult: result,
                finalText: polished.text,
                sourceText: polished.sourceText,
                action: .insertAndSubmit,
                aiWorkflowName: nil,
                aiProvider: nil,
                submitWarning: submitWarning,
                dictationPolishingApplied: polished.applied,
                dictationPolishingSkippedReason: polished.skippedReason
            )

        case .aiWorkflow(let workflowID):
            guard let workflow = workflows.first(where: { $0.id == workflowID }) else {
                throw CompletionRoutingError.workflowNotFound(workflowID)
            }
            let aiResult = try await aiGenerationService.generate(workflow: workflow, input: routedCompletion.inputText)
            var result = await insertionService.insert(
                text: aiResult.outputText,
                target: finalizedTranscript.appContext
            )
            result.cleanupOutcome = finalizedTranscript.cleanupOutcome
            return CompletionExecutionOutcome(
                insertResult: result,
                finalText: aiResult.outputText,
                sourceText: routedCompletion.inputText,
                action: routedCompletion.action,
                aiWorkflowName: workflow.name,
                aiProvider: aiResult.provider,
                submitWarning: nil
            )
        }
    }

    private func polishedDictationTextIfNeeded(
        _ text: String,
        enabled: Bool
    ) async -> (text: String, sourceText: String?, applied: Bool, skippedReason: String?) {
        guard enabled else {
            return (text, nil, false, nil)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (text, nil, false, nil)
        }

        do {
            let result = try await aiGenerationService.generate(
                workflow: .dictationPolishWorkflow,
                input: text
            )
            let output = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                return (text, nil, false, "AI returned no output.")
            }
            let sourceText = output == text ? nil : text
            return (output, sourceText, true, nil)
        } catch let error as AIWorkflowError {
            return (text, nil, false, error.errorDescription ?? "AI polish failed.")
        } catch {
            return (text, nil, false, error.localizedDescription)
        }
    }
}
