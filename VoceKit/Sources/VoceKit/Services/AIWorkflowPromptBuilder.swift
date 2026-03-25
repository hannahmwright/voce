import Foundation

public enum AIWorkflowPromptBuilder {
    public static func makePrompt(for workflow: AIWorkflow, input: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = workflow.effectivePromptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !template.isEmpty else {
            return trimmedInput
        }
        if template.contains("{{input}}") {
            return template.replacingOccurrences(of: "{{input}}", with: trimmedInput)
        }
        return "\(template)\n\n\(trimmedInput)"
    }
}
