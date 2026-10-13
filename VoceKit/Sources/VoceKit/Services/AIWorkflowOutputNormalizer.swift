import Foundation

public enum AIWorkflowOutputNormalizer {
    /// Strips an assistant preamble ("Sure, here's the rewritten text:") from
    /// AI workflow output.
    ///
    /// - Parameter input: The text sent to the model. When the input itself
    ///   starts with the would-be preamble (the user dictated "Here's my
    ///   email: …"), nothing is stripped.
    public static func normalize(_ output: String, for workflow: AIWorkflow, input: String? = nil) -> String {
        normalize(output, kind: workflow.kind, input: input)
    }

    public static func normalize(_ output: String, kind: AIWorkflowKind, input: String? = nil) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        guard let vocabulary = Vocabulary(kind: kind) else {
            return trimmed
        }
        return normalizeDirectiveOutput(trimmed, vocabulary: vocabulary, input: input)
    }

    /// Words that may close a preamble, per workflow kind.
    private struct Vocabulary {
        /// Bare labels: "Summary", "Rewritten text", "Polished text".
        var labels: [String]
        /// Modifiers that make a generic noun an assistant label
        /// ("rewritten email", "cleaned-up transcript").
        var modifiers: [String]
        /// Generic nouns allowed after a modifier.
        var nouns: [String]
        /// Nouns that close a "here's …" preamble on their own
        /// ("Here's a friendlier version").
        var bareNouns: [String] = []
        /// Nouns accepted only as "here's the/your <noun>:" ending in a colon
        /// ("Here's the email:").
        var colonOnlyNouns: [String] = []

        init?(kind: AIWorkflowKind) {
            switch kind {
            case .rewrite:
                labels = ["rewrite", "rewritten text", "revised text"]
                modifiers = [
                    "rewritten", "revised", "polished", "updated", "improved", "edited", "refined",
                    "clearer", "tighter", "concise", "shorter", "cleaner", "reworded",
                ]
                nouns = ["email", "message", "draft", "reply", "response", "note", "notes", "text", "version", "paragraph", "prompt"]
                bareNouns = ["version", "text"]
                colonOnlyNouns = ["email", "message"]
            case .summarize:
                labels = ["summary", "summarized text", "concise summary"]
                modifiers = ["summarized", "condensed", "concise", "brief", "short"]
                nouns = ["version", "text", "notes", "overview", "recap", "summary"]
                bareNouns = ["version", "text"]
            case .dictationPolish:
                // Only explicit cleanup labels; generic nouns such as "email"
                // or "draft" are the user's own words in dictation.
                labels = ["cleaned text", "polished text", "formatted text", "cleaned-up text"]
                modifiers = ["polished", "cleaned-up", "cleaned up", "cleaned", "formatted", "corrected"]
                nouns = ["text", "transcript", "version", "dictation"]
            case .ask, .customPrompt:
                return nil
            }
        }
    }

    private static func normalizeDirectiveOutput(_ text: String, vocabulary: Vocabulary, input: String?) -> String {
        if let strippedInline = stripInlinePreamble(from: text, vocabulary: vocabulary, input: input) {
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

        if lines.count > 1,
           isPreambleCandidate(
               firstLine,
               vocabulary: vocabulary,
               endsWithColon: firstLine.trimmingCharacters(in: .whitespaces).hasSuffix(":")
           ),
           !inputStarts(with: firstLine, input: input) {
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

    private static func stripInlinePreamble(from text: String, vocabulary: Vocabulary, input: String?) -> String? {
        guard let separator = text.firstIndex(of: ":") else {
            return nil
        }

        let prefix = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text[text.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !suffix.isEmpty, prefix.count <= 90 else {
            return nil
        }

        guard isPreambleCandidate(prefix, vocabulary: vocabulary, endsWithColon: true), !inputStarts(with: prefix, input: input) else {
            return nil
        }

        return suffix
    }

    /// The model's input begins with the same words as the would-be preamble,
    /// so it is the user's content, not the assistant's.
    private static func inputStarts(with prefix: String, input: String?) -> Bool {
        guard let input else { return false }
        let normalizedPrefix = WordTokenizer.normalizedText(prefix)
        guard !normalizedPrefix.isEmpty else { return false }
        let normalizedInput = WordTokenizer.normalizedText(input)
        return normalizedInput == normalizedPrefix || normalizedInput.hasPrefix(normalizedPrefix + " ")
    }

    /// Whether `text` (a first line, or the text before the first colon) is
    /// entirely an assistant preamble. Only tight patterns qualify, so real
    /// content that merely starts with "Okay", "Here's", or mentions a label
    /// word ("The summary deadline", "Here's my email") is never stripped:
    /// - a bare label, optionally "of <up to three words>": "Summary of key points"
    /// - "[Sure, ]here's [the|a|your] [up to three words] <label | modifier noun>
    ///   [of <up to three words>]": "Here is the rewritten email"
    /// - an acknowledgement: "Sure, I can do that.", "Certainly!"
    private static func isPreambleCandidate(_ text: String, vocabulary: Vocabulary, endsWithColon: Bool) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        func alternatives(_ words: [String]) -> String {
            words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        }
        let labels = alternatives(vocabulary.labels)
        let modifiedNoun = "(?:\(alternatives(vocabulary.modifiers)))\\s+(?:\(alternatives(vocabulary.nouns)))"
        let opener = #"(?:sure|certainly|absolutely|of course|okay|ok)\b"#
        let here = #"(?:here(?:'|\x{2019})s|here is|below is)"#
        let ofPhrase = #"(?:\s+of\s+(?:(?:the|your|this|my|our)\s+)?[\p{L}-]+(?:\s+[\p{L}-]+){0,2})?"#
        var heads = ["(?:\(here)\\s+(?:(?:the|a|an|your)\\s+)?(?:[\\p{L}-]+\\s+){0,3}?(?:\(labels)|\(modifiedNoun)))"]
        if !vocabulary.bareNouns.isEmpty {
            // "Here's a more professional version" (not "Here's my text").
            heads.append(
                "(?:\(here)\\s+(?:(?:the|a|an|your)\\s+)?(?!(?:my|our)\\b)(?:[\\p{L}-]+\\s+){0,3}?(?:\(alternatives(vocabulary.bareNouns))))"
            )
        }
        if endsWithColon, !vocabulary.colonOnlyNouns.isEmpty {
            heads.append("(?:\(here)\\s+(?:the|your)\\s+(?:\(alternatives(vocabulary.colonOnlyNouns))))")
        }
        heads.append("(?:\(labels))")
        let labelPattern = "^(?:\(opener)[\\s,!.]*)?(?:" + heads.joined(separator: "|") + ")\(ofPhrase)$"
        let acknowledgementPattern = "^\(opener)(?:[\\s,!.]+(?:i can do that|i can help with that|here you go|here it is|no problem|happy to help))?$"

        return [labelPattern, acknowledgementPattern].contains { pattern in
            guard let regex = regexCache.regex(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
        }
    }

    private static let regexCache = RegexCache(capacity: 32)
}
