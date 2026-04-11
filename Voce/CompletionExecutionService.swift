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
}

@MainActor
struct CompletionExecutionService {
    let insertionService: any InsertionServiceProtocol
    let clipboardService: any ClipboardService
    let aiGenerationService: AppleFoundationModelsService

    func execute(
        routedCompletion: RoutedCompletion,
        finalizedTranscript: FinalizedTranscript,
        workflows: [AIWorkflow]
    ) async throws -> CompletionExecutionOutcome {
        switch routedCompletion.action {
        case .insert:
            var result = await insertionService.insert(
                text: finalizedTranscript.cleanText,
                target: finalizedTranscript.appContext
            )
            result.cleanupOutcome = finalizedTranscript.cleanupOutcome
            return CompletionExecutionOutcome(
                insertResult: result,
                finalText: finalizedTranscript.cleanText,
                sourceText: nil,
                action: .insert,
                aiWorkflowName: nil,
                aiProvider: nil,
                submitWarning: nil
            )

        case .copyToClipboard:
            do {
                try await clipboardService.setString(finalizedTranscript.cleanText)
                var result = InsertResult(
                    status: .copiedOnly,
                    method: .clipboardPaste,
                    insertedText: finalizedTranscript.cleanText
                )
                result.cleanupOutcome = finalizedTranscript.cleanupOutcome
                return CompletionExecutionOutcome(
                    insertResult: result,
                    finalText: finalizedTranscript.cleanText,
                    sourceText: nil,
                    action: .copyToClipboard,
                    aiWorkflowName: nil,
                    aiProvider: nil,
                    submitWarning: nil
                )
            } catch {
                var result = InsertResult(
                    status: .failed,
                    method: .none,
                    insertedText: finalizedTranscript.cleanText,
                    errorMessage: error.localizedDescription
                )
                result.cleanupOutcome = finalizedTranscript.cleanupOutcome
                return CompletionExecutionOutcome(
                    insertResult: result,
                    finalText: finalizedTranscript.cleanText,
                    sourceText: nil,
                    action: .copyToClipboard,
                    aiWorkflowName: nil,
                    aiProvider: nil,
                    submitWarning: nil
                )
            }

        case .insertAndSubmit:
            var result = await insertionService.insert(
                text: finalizedTranscript.cleanText,
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
                finalText: finalizedTranscript.cleanText,
                sourceText: nil,
                action: .insertAndSubmit,
                aiWorkflowName: nil,
                aiProvider: nil,
                submitWarning: submitWarning
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
}
