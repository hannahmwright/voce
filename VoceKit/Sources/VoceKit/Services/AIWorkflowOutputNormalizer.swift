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

    /// Whether `text` (a first line, or the text before the first colon) is
    /// entirely an assistant preamble. Only tight patterns qualify, so real
    /// content that merely starts with "Okay", "Here's", or mentions a label
    /// word ("The summary deadline") is never stripped:
    /// - a bare label: "Summary", "Rewritten text"
    /// - "[Sure, ]here's [the|a] [up to three words] <label|version|text> [of the text]"
    /// - an acknowledgement: "Sure, I can do that.", "Certainly!"
    private static func isPreambleCandidate(_ text: String, labels: [String]) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        let labelAlternatives = labels
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let opener = #"(?:sure|certainly|absolutely|of course|okay|ok)\b"#
        let here = #"(?:here(?:'|\x{2019})s|here is|below is)"#
        let ofTheText = #"(?:\s+of\s+(?:the|your)\s+(?:text|input|transcript|message|note))?"#
        let labelPattern = "^(?:\(opener)[\\s,!.]*)?"
            + "(?:\(here)\\s+(?:(?:the|a|an|your|my)\\s+)?(?:[\\p{L}-]+\\s+){0,3}?(?:\(labelAlternatives)|version|text)"
            + "|(?:\(labelAlternatives)))\(ofTheText)$"
        let acknowledgementPattern = "^\(opener)(?:[\\s,!.]+(?:i can do that|i can help with that|here you go|here it is|no problem|happy to help))?$"

        return [labelPattern, acknowledgementPattern].contains { pattern in
            guard let regex = regexCache.regex(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
        }
    }

    private static let regexCache = RegexCache(capacity: 32)
}
