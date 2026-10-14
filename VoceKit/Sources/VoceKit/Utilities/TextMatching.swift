import Foundation
import os

/// Shared helpers for matching user-defined terms (lexicon entries, snippet
/// triggers, voice commands) inside transcript text.
public enum TextMatching {
    /// Lookbehind asserting the match does not start inside a word.
    ///
    /// Unlike `\b`, this works for terms that begin or end with symbols such as
    /// `C#`, `.net`, or `@@sig`: `\b` requires a word character on one side, so
    /// it never matches between a space and `#`/`.`/`@`.
    public static let termStartBoundary = "(?<![\\p{L}\\p{N}_])"

    /// Lookahead asserting the match does not end inside a word.
    public static let termEndBoundary = "(?![\\p{L}\\p{N}_])"

    /// A regex pattern matching `term` literally as a whole term.
    public static func wholeTermPattern(for term: String) -> String {
        termStartBoundary + NSRegularExpression.escapedPattern(for: term) + termEndBoundary
    }

    /// Returns a compiled case-insensitive regex matching `term` as a whole term,
    /// reusing `cache` so repeated calls do not recompile the pattern.
    public static func wholeTermRegex(for term: String, cache: RegexCache) -> NSRegularExpression? {
        cache.regex(pattern: wholeTermPattern(for: term), options: [.caseInsensitive])
    }
}

/// Thread-safe cache of compiled regular expressions.
///
/// `NSRegularExpression` is immutable and safe to share across threads, so a
/// compiled instance can be reused by any caller. The cache is bounded; when it
/// fills up it is cleared rather than growing without limit. Owners keep their
/// own instance (typically a private static constant next to their other
/// precompiled patterns).
public final class RegexCache: Sendable {
    private struct Key: Hashable, Sendable {
        var pattern: String
        var options: UInt
    }

    private let storage = OSAllocatedUnfairLock<[Key: NSRegularExpression]>(initialState: [:])
    private let capacity: Int

    public init(capacity: Int = 1_024) {
        self.capacity = max(1, capacity)
    }

    public func regex(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        if let cached = storage.withLock({ $0[key] }) {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        storage.withLock { cache in
            if cache.count >= capacity {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = compiled
        }
        return compiled
    }
}

/// Unicode-aware word tokenizer shared by the cleanup ranker and the learning engine.
///
/// - Lowercases the input.
/// - Keeps letters (including accented letters such as `é`), digits, and
///   apostrophes inside words, so `don't` stays one token and `café` is not
///   truncated.
/// - Normalizes typographic apostrophes (`’`, `‘`, `ʼ`) to `'` and trims
///   apostrophes at word edges (`'quoted'` → `quoted`).
public enum WordTokenizer {
    public static func words(in text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            let token = String(current).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !token.isEmpty {
                tokens.append(token)
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in text.lowercased().unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if isApostrophe(scalar) {
                current.append("'")
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Space-joined lowercase tokens; convenient for phrase containment checks.
    public static func normalizedText(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        // Private-use scalars form snippet placeholders; counting a placeholder
        // as one word keeps ranking the same as for the trigger it replaced.
        case .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark, .privateUse:
            return true
        default:
            return false
        }
    }

    private static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "'", "\u{2019}", "\u{2018}", "\u{02BC}":
            return true
        default:
            return false
        }
    }
}
