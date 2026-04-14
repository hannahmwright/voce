import Foundation

public enum AIWorkflowOutputNormalizer {
    public static func normalize(_ output: String, for workflow: AIWorkflow) -> String {
        normalize(output, kind: workflow.kind)
    }

    public static func normalize(_ output: String, kind: AIWorkflowKind) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        switch kind {
        case .rewrite:
            return normalizeDirectiveOutput(
                trimmed,
                labels: ["rewrite", "rewritten text", "revised text"]
            )
        case .summarize:
            return normalizeDirectiveOutput(
                trimmed,
                labels: ["summary", "summarized text", "concise summary"]
            )
        case .dictationPolish:
            return normalizeDirectiveOutput(
                trimmed,
                labels: ["cleaned text", "polished text", "formatted text", "cleaned-up text"]
            )
        case .ask, .customPrompt:
            return trimmed
        }
    }

    private static func normalizeDirectiveOutput(_ text: String, labels: [String]) -> String {
        if let strippedInline = stripInlinePreamble(from: text, labels: labels) {
            return strippedInline
        }

        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        guard let firstLine = lines.first else {
            return text
        }

        if isPreambleCandidate(firstLine, labels: labels), lines.count > 1 {
            let remainder = lines
                .dropFirst()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !remainder.isEmpty {
                return remainder
            }
        }

        return text
    }

    private static func stripInlinePreamble(from text: String, labels: [String]) -> String? {
        guard let separator = text.firstIndex(of: ":") else {
            return nil
        }

        let prefix = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text[text.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !suffix.isEmpty, prefix.count <= 90 else {
            return nil
        }

        guard isPreambleCandidate(prefix, labels: labels) else {
            return nil
        }

        return suffix
    }

    private static func isPreambleCandidate(_ text: String, labels: [String]) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        let conversationalPrefixes = [
            "sure",
            "certainly",
            "absolutely",
            "of course",
            "okay",
            "ok",
            "here is",
            "here's"
        ]

        if conversationalPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        return labels.contains(where: { normalized.contains($0) })
    }
}
