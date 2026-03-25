import Foundation
import Testing
@testable import VoceKit

@Test("AIWorkflowPromptBuilder includes transcript text for ask")
func promptBuilderAskPromptIncludesInput() {
    let workflow = AIWorkflow.builtIns.first { $0.id == AIWorkflow.askID }!
    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "How do I write this?")
    #expect(prompt.contains("How do I write this?"))
}

@Test("AIWorkflowPromptBuilder interpolates custom templates")
func promptBuilderInterpolatesCustomTemplate() {
    let workflow = AIWorkflow(
        id: UUID(),
        name: "Custom Prompt",
        kind: .customPrompt,
        promptTemplate: "Make this more concise: {{input}}"
    )

    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "Long draft")
    #expect(prompt == "Make this more concise: Long draft")
}

@Test("AIWorkflowPromptBuilder appends input when custom template has no placeholder")
func promptBuilderAppendsInputWithoutPlaceholder() {
    let workflow = AIWorkflow(
        id: UUID(),
        name: "Custom Prompt",
        kind: .customPrompt,
        promptTemplate: "Turn this into bullets."
    )

    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "alpha beta")
    #expect(prompt == "Turn this into bullets.\n\nalpha beta")
}
