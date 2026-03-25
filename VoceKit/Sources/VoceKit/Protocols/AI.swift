import Foundation

public protocol AITextGenerationService: Sendable {
    func generate(workflow: AIWorkflow, input: String) async throws -> AIWorkflowResult
}

