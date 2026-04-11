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

@Test("Directive output normalizer preserves normal content")
func directiveOutputNormalizerPreservesCleanContent() {
    let output = "This version is tighter and clearer without changing the meaning."

    let normalized = AIWorkflowOutputNormalizer.normalize(output, kind: .rewrite)

    #expect(normalized == output)
}
