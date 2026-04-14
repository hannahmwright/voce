import Foundation
import Testing
@testable import VoceKit

@Test("AIWorkflowPromptBuilder includes transcript text for ask")
func promptBuilderAskPromptIncludesInput() {
    let workflow = AIWorkflow.builtIns.first { $0.id == AIWorkflow.askID }!
    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "How do I write this?")
    #expect(prompt.contains("How do I write this?"))
}

@Test("AI workflow built-ins include AI Prompt with period finish key")
func aiWorkflowBuiltInsIncludeAIPrompt() {
    let workflow = AIWorkflow.builtIns.first { $0.id == AIWorkflow.aiPromptID }

    #expect(workflow?.name == "AI Prompt")
    #expect(workflow?.handsFreeFinishHotkey == .keyCode(47))
    #expect(workflow?.isBuiltIn == true)
    #expect(workflow?.promptTemplate?.contains("Convert the following transcription into a clear and effective prompt") == true)
}

@Test("Rewrite built-in prompt is explicit about output-only behavior")
func rewritePromptTemplateIsStrict() {
    let workflow = AIWorkflow.builtIns.first { $0.id == AIWorkflow.rewriteID }!
    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "Make this tighter")

    #expect(prompt.contains("Return only the rewritten text"))
    #expect(prompt.contains("Do not say things like"))
}

@Test("Dictation polish prompt is conservative and output-only")
func dictationPolishPromptTemplateIsStrict() {
    let prompt = AIWorkflowPromptBuilder.makePrompt(
        for: .dictationPolishWorkflow,
        input: "first thing eggs second thing milk"
    )

    #expect(prompt.contains("Clean up this dictated text for insertion."))
    #expect(prompt.contains("Preserve the user's meaning and wording as much as possible"))
    #expect(prompt.contains("Use bullet points or numbered lists only when the text clearly asks for a list or sequence"))
    #expect(prompt.contains("Do not answer questions"))
    #expect(prompt.contains("Return only the cleaned text"))
    #expect(prompt.contains("first thing eggs second thing milk"))
}

@Test("Dictation polish workflow is not exposed as a user action")
func dictationPolishWorkflowIsHiddenFromBuiltIns() {
    #expect(!AIWorkflow.builtIns.contains { $0.id == AIWorkflow.dictationPolishWorkflow.id })
}

@Test("AIWorkflowPromptBuilder uses explicit prompt template overrides for built-in workflows")
func promptBuilderUsesBuiltInPromptOverride() {
    let workflow = AIWorkflow(
        id: AIWorkflow.askID,
        name: "Ask AI",
        kind: .ask,
        promptTemplate: "Turn this into a sharper request: {{input}}",
        isBuiltIn: true
    )

    let prompt = AIWorkflowPromptBuilder.makePrompt(for: workflow, input: "draft request")
    #expect(prompt == "Turn this into a sharper request: draft request")
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
