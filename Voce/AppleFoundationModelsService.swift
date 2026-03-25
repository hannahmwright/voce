import Foundation
import FoundationModels
import VoceKit

enum AppleFoundationModelsAvailabilityStatus: Equatable {
    case available
    case unavailable(String)

    var displayText: String {
        switch self {
        case .available:
            return "Apple Intelligence is available on this Mac."
        case .unavailable(let reason):
            return reason
        }
    }

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

struct AppleFoundationModelsService: AITextGenerationService {
    func availabilityStatus() -> AppleFoundationModelsAvailabilityStatus {
        guard #available(macOS 26.0, *) else {
            return .unavailable("Apple Intelligence requires macOS 26 or later.")
        }

        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reasonText(for: reason))
        }
    }

    func generate(workflow: AIWorkflow, input: String) async throws -> AIWorkflowResult {
        let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: input)
        let startedAt = Date()

        guard #available(macOS 26.0, *) else {
            throw AIWorkflowError.unavailable(reason: "Apple Intelligence requires macOS 26 or later.")
        }

        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AIWorkflowError.unavailable(reason: reasonText(for: reason))
        }

        let session = LanguageModelSession(model: model)

        do {
            let response = try await session.respond(to: prompt)
            let outputText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !outputText.isEmpty else {
                throw AIWorkflowError.emptyOutput
            }
            return AIWorkflowResult(
                outputText: outputText,
                provider: .appleFoundationModels,
                modelDescription: "Apple Foundation Models",
                latencyMS: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
        } catch is CancellationError {
            throw AIWorkflowError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        } catch let error as AIWorkflowError {
            throw error
        } catch {
            throw AIWorkflowError.generationFailed(reason: error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> AIWorkflowError {
        switch error {
        case .assetsUnavailable:
            return .unavailable(reason: "Apple Intelligence model assets aren't ready yet.")
        case .refusal(_, let context):
            return .generationFailed(reason: context.debugDescription)
        default:
            return .generationFailed(reason: error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private func reasonText(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off."
        case .modelNotReady:
            return "Apple Intelligence is still downloading or preparing the model."
        @unknown default:
            return "Apple Intelligence is unavailable on this Mac."
        }
    }
}
