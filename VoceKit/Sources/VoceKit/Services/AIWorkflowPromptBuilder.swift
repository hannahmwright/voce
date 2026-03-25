import Foundation

public enum AIWorkflowPromptBuilder {
    public static func makePrompt(for workflow: AIWorkflow, input: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        switch workflow.kind {
        case .ask:
            return """
            Answer the user's request clearly and directly.

            User request:
            \(trimmedInput)
            """
        case .rewrite:
            return """
            Rewrite the following text for clarity and flow while preserving its meaning and tone. Return only the rewritten text.

            Text:
            \(trimmedInput)
            """
        case .summarize:
            return """
            Summarize the following text concisely. Return only the summary.

            Text:
            \(trimmedInput)
            """
        case .customPrompt:
            let template = workflow.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !template.isEmpty else {
                return trimmedInput
            }
            if template.contains("{{input}}") {
                return template.replacingOccurrences(of: "{{input}}", with: trimmedInput)
            }
            return "\(template)\n\n\(trimmedInput)"
        }
    }
}

