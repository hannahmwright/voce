import Foundation

public enum ConsecutivePhraseDeduplicator {
    private static let minimumRepeatedTokenCount = 4
    private static let minimumRepeatedCharacterCount = 16

    public static func collapse(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= minimumRepeatedTokenCount * 2 else {
            return trimmed
        }
        var normalizedTokens = tokens.map(normalizeToken)

        var changed = true
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

                    tokens.removeSubrange(rhsRange)
                    normalizedTokens.removeSubrange(rhsRange)
                    changed = true
                    removedSpan = true
                    break
                }

                if !removedSpan {
                    index += 1
                }
            }
        }

        return tokens.joined(separator: " ")
    }

    private static func normalizeToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
