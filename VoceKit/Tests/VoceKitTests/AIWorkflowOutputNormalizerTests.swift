import Testing
@testable import VoceKit

@Test("Rewrite output normalizer strips inline assistant preamble")
func rewriteOutputNormalizerStripsInlinePreamble() {
    let output = "Sure, here's the rewritten text: This version is tighter and clearer."

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .rewrite)

    #expect(normalized == "This version is tighter and clearer.")
}

@Test("Rewrite output normalizer strips first-line assistant preamble")
func rewriteOutputNormalizerStripsLeadingLine() {
    let output = """
    Sure, I can do that.
    This version is tighter and clearer.
    """

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .rewrite)

    #expect(normalized == "This version is tighter and clearer.")
}

@Test("Summarize output normalizer strips summary labels")
func summarizeOutputNormalizerStripsLabel() {
    let output = """
    Summary:
    The note explains the launch plan and the next milestones.
    """

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .summarize)

    #expect(normalized == "The note explains the launch plan and the next milestones.")
}

@Test("Dictation polish output normalizer strips polish labels")
func dictationPolishOutputNormalizerStripsLabel() {
    let output = """
    Polished text:
    First, buy eggs. Second, buy milk.
    """

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .dictationPolish)

    #expect(normalized == "First, buy eggs. Second, buy milk.")
}

@Test("Directive output normalizer preserves normal content")
func directiveOutputNormalizerPreservesCleanContent() {
    let output = "This version is tighter and clearer without changing the meaning."

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .rewrite)

    #expect(normalized == output)
}

@Test(
    "Directive output normalizer keeps real content that resembles a preamble",
    arguments: [
        (AIWorkflowKind.rewrite, "Okay team, here are the dates: Monday and Friday."),
        (AIWorkflowKind.summarize, "The summary deadline: Friday at noon."),
        (AIWorkflowKind.rewrite, "Here's the plan for Q3.\nWe ship Monday."),
        (AIWorkflowKind.rewrite, "Okta rollout: finished on Tuesday."),
        (AIWorkflowKind.rewrite, "Okta rollout\nFinished on Tuesday."),
        (AIWorkflowKind.summarize, "Summary of findings from the audit team: three gaps remain."),
        (AIWorkflowKind.dictationPolish, "Of course we can meet: Tuesday works."),
        (AIWorkflowKind.rewrite, "Sure thing, I'll send the revised text: tomorrow."),
    ]
)
func directiveOutputNormalizerKeepsPreambleLookalikes(kind: AIWorkflowKind, output: String) {
    #expect(AIWorkflowOutputNormalizer.normalize(output, kind: kind) == output)
}

@Test(
    "Directive output normalizer strips common here's/summary preambles",
    arguments: [
        (AIWorkflowKind.summarize, "Here's a summary of the meeting:"),
        (AIWorkflowKind.summarize, "Here is a concise summary of the discussion:"),
        (AIWorkflowKind.rewrite, "Here is the rewritten email:"),
        (AIWorkflowKind.rewrite, "Here's your rewritten message:"),
        (AIWorkflowKind.summarize, "Summary of key points:"),
        (AIWorkflowKind.dictationPolish, "Here's the cleaned-up transcript:"),
    ]
)
func directiveOutputNormalizerStripsHerePreambles(kind: AIWorkflowKind, preamble: String) {
    #expect(AIWorkflowOutputNormalizer.normalize("\(preamble) We ship Monday.", kind: kind) == "We ship Monday.")
    #expect(AIWorkflowOutputNormalizer.normalize("\(preamble)\nWe ship Monday.", kind: kind) == "We ship Monday.")
}

@Test("Directive output normalizer keeps \"Here's the thing:\" content")
func directiveOutputNormalizerKeepsHeresTheThing() {
    let output = "Here's the thing: we ship Monday."
    #expect(AIWorkflowOutputNormalizer.normalize(output, kind: .rewrite) == output)
}

@Test("Directive output normalizer still strips common assistant preambles")
func directiveOutputNormalizerStripsCommonPreambles() {
    #expect(
        AIWorkflowOutputNormalizer.normalize("Here\u{2019}s a more concise version:\nWe ship Monday.", kind: .rewrite)
            == "We ship Monday."
    )
    #expect(
        AIWorkflowOutputNormalizer.normalize("Here is a concise summary of the text: We ship Monday.", kind: .summarize)
            == "We ship Monday."
    )
    #expect(
        AIWorkflowOutputNormalizer.normalize("Certainly!\nWe ship Monday.", kind: .rewrite)
            == "We ship Monday."
    )
    #expect(
        AIWorkflowOutputNormalizer.normalize("Sure! Here's the rewrite:\n\nWe ship Monday.", kind: .rewrite)
            == "We ship Monday."
    )
}
