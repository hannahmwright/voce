import Foundation

public enum ConsecutivePhraseDeduplicator {
    private static let minimumRepeatedTokenCount = 4
    private static let minimumRepeatedCharacterCount = 16

    public static func collapse(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Keep each token's trailing separator so line breaks (and any other
        // original whitespace) survive when a repeated span is removed.
        var tokens: [String] = []
        var separators: [String] = []
        var currentToken = ""
        var currentSeparator = ""
        for character in trimmed {
            if character.isWhitespace {
                currentSeparator.append(character)
            } else {
                if !currentSeparator.isEmpty {
                    tokens.append(currentToken)
                    separators.append(currentSeparator)
                    currentToken = ""
                    currentSeparator = ""
                }
                currentToken.append(character)
            }
        }
        tokens.append(currentToken)
        separators.append("")

        guard tokens.count >= minimumRepeatedTokenCount * 2 else {
            return trimmed
        }
        var normalizedTokens = tokens.map(normalizeToken)

        var changed = true
        var removedAny = false
        while changed {
            changed = false
            var index = 0

            while index < tokens.count {
                let maxSpan = (tokens.count - index) / 2
                guard maxSpan >= minimumRepeatedTokenCount else { break }

                var removedSpan = false
                for span in stride(from: maxSpan, through: minimumRepeatedTokenCount, by: -1) {
                    let lhsRange = index..<(index + span)
                    let rhsRange = (index + span)..<(index + (span * 2))
                    guard normalizedTokens[lhsRange].elementsEqual(normalizedTokens[rhsRange]) else { continue }

                    let repeatedText = tokens[lhsRange].joined(separator: " ")
                    guard repeatedText.count >= minimumRepeatedCharacterCount else { continue }

                    // The kept span ends with the separator that followed the
                    // removed span, so text after it stays correctly spaced.
                    separators[lhsRange.upperBound - 1] = separators[rhsRange.upperBound - 1]
                    tokens.removeSubrange(rhsRange)
                    separators.removeSubrange(rhsRange)
                    normalizedTokens.removeSubrange(rhsRange)
                    changed = true
                    removedAny = true
                    removedSpan = true
                    break
                }

                if !removedSpan {
                    index += 1
                }
            }
        }

        guard removedAny else { return trimmed }
        return zip(tokens, separators).map { $0 + $1 }.joined()
    }

    private static func normalizeToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
