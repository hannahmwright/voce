import Foundation

public actor SnippetService {
    private struct CompiledSnippets: Sendable {
        var regex: NSRegularExpression
        /// Expansion keyed by lowercased trigger. App-specific snippets win over
        /// global snippets that share a trigger.
        var expansionsByTrigger: [String: String]
    }

    private var snippets: [Snippet]
    /// Compiled matchers keyed by the app bundle ID they were built for
    /// (empty string for "no app"). Invalidated on mutation.
    private var compiledCache: [String: CompiledSnippets] = [:]

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    public func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        compiledCache.removeAll()
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        compiledCache.removeAll()
    }

    public func list() -> [Snippet] {
        snippets
    }

    /// Expands snippet triggers in a single left-to-right pass.
    ///
    /// - Longer triggers win over shorter triggers they contain
    ///   ("my work address" beats "my work").
    /// - App-specific snippets win over global snippets with the same trigger.
    /// - Expanded text is never re-scanned, so an expansion that happens to
    ///   contain another trigger is inserted verbatim.
    /// - Words in a trigger match across any whitespace ("my\n\nsig").
    public func apply(to text: String, appContext: AppContext?) -> String {
        let protected = protect(text, appContext: appContext)
        return protected.restore(in: protected.text, capitalizingSentenceStarts: false)
    }

    /// Replaces snippet triggers with opaque placeholders so the text can go
    /// through cleanup, voice commands and cloud refinement without the
    /// triggers (or their expansions) being altered. Call
    /// ``SnippetProtectedText/restore(in:capitalizingSentenceStarts:)`` on the
    /// processed text to insert the expansions.
    public func protect(_ text: String, appContext: AppContext?) -> SnippetProtectedText {
        guard !text.isEmpty, let compiled = compiled(for: appContext?.bundleIdentifier) else {
            return SnippetProtectedText(text: text, expansions: [:])
        }

        let nsText = text as NSString
        let matches = compiled.regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return SnippetProtectedText(text: text, expansions: [:]) }

        var result = ""
        var cursor = 0
        var expansions: [String: String] = [:]
        for match in matches {
            let matchedTrigger = Self.normalizedTrigger(nsText.substring(with: match.range))
            guard let expansion = compiled.expansionsByTrigger[matchedTrigger] else { continue }
            let placeholder = SnippetProtectedText.placeholder(index: expansions.count)
            expansions[placeholder] = expansion
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += placeholder
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return SnippetProtectedText(text: result, expansions: expansions)
    }

    private static func normalizedTrigger(_ trigger: String) -> String {
        trigger.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func compiled(for bundleIdentifier: String?) -> CompiledSnippets? {
        let cacheKey = bundleIdentifier ?? ""
        if let cached = compiledCache[cacheKey] {
            return cached
        }

        var appSpecific: [Snippet] = []
        var global: [Snippet] = []
        for snippet in snippets where !snippet.trigger.isEmpty {
            switch snippet.scope {
            case .global:
                global.append(snippet)
            case .app(let bundleID):
                if bundleID == bundleIdentifier {
                    appSpecific.append(snippet)
                }
            }
        }

        var expansionsByTrigger: [String: String] = [:]
        // App-specific first so they claim a trigger before a global duplicate;
        // within a scope the first-defined snippet wins (matches prior behaviour).
        for snippet in appSpecific + global {
            let key = Self.normalizedTrigger(snippet.trigger)
            guard !key.isEmpty else { continue }
            if expansionsByTrigger[key] == nil {
                expansionsByTrigger[key] = snippet.expansion
            }
        }
        guard !expansionsByTrigger.isEmpty else { return nil }

        // Regex alternation is ordered, so listing longer triggers first makes
        // the longest trigger win at any given position.
        let alternatives = expansionsByTrigger.keys
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
            }
            .map { trigger in
                trigger
                    .split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            .joined(separator: "|")
        let pattern = TextMatching.termStartBoundary + "(?:" + alternatives + ")" + TextMatching.termEndBoundary
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let compiled = CompiledSnippets(regex: regex, expansionsByTrigger: expansionsByTrigger)
        compiledCache[cacheKey] = compiled
        return compiled
    }
}

/// Text whose snippet triggers were replaced by opaque placeholders.
///
/// Placeholders consist only of Unicode private-use characters, so no cleanup
/// step that works on letters, digits, whitespace or punctuation (filler
/// removal, lexicon, voice commands, list formatting) can match or alter
/// them. They are invisible to the word tokenizer used by the ranker.
public struct SnippetProtectedText: Sendable, Equatable {
    /// The text with placeholders in place of snippet triggers.
    public var text: String
    /// Expansion for each placeholder.
    public var expansions: [String: String]

    public init(text: String, expansions: [String: String]) {
        self.text = text
        self.expansions = expansions
    }

    public var hasPlaceholders: Bool { !expansions.isEmpty }

    static let placeholderStart: Unicode.Scalar = "\u{E000}"
    static let placeholderEnd: Unicode.Scalar = "\u{E001}"
    /// Base of the private-use "digits" used for placeholder ids.
    static let placeholderDigitBase: UInt32 = 0xE010

    static func placeholder(index: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(placeholderStart)
        for digit in String(index) {
            guard let value = digit.wholeNumberValue,
                  let scalar = Unicode.Scalar(placeholderDigitBase + UInt32(value)) else { continue }
            scalars.append(scalar)
        }
        scalars.append(placeholderEnd)
        return String(scalars)
    }

    /// Every placeholder appears exactly once in `processed` (e.g. after cloud
    /// refinement); otherwise the processed text must not be trusted.
    public func placeholdersAreIntact(in processed: String) -> Bool {
        guard hasPlaceholders else { return true }
        for placeholder in expansions.keys {
            guard processed.components(separatedBy: placeholder).count == 2 else { return false }
        }
        // No stray placeholder fragments beyond the expected ones.
        let delimiterCount = processed.unicodeScalars.filter { $0 == Self.placeholderStart }.count
        return delimiterCount == expansions.count
    }

    /// Replaces placeholders in `processed` with their expansions, verbatim
    /// (line breaks kept). With `capitalizingSentenceStarts`, an expansion that
    /// lands at the start of the text or of a sentence gets its first letter
    /// capitalized ("brb see you" → "Be right back see you"), unless its first
    /// word looks deliberately cased (an email, URL or "iPhone").
    public func restore(in processed: String, capitalizingSentenceStarts: Bool = true) -> String {
        guard hasPlaceholders else { return processed }
        var result = processed
        // Longest placeholder first so "…1…" never matches inside "…10…"
        // (delimiters already prevent this; ordering keeps it obvious).
        for (placeholder, expansion) in expansions.sorted(by: { $0.key.count > $1.key.count }) {
            while let range = result.range(of: placeholder) {
                var replacement = expansion
                if capitalizingSentenceStarts, Self.isSentenceStart(in: result, before: range.lowerBound) {
                    replacement = Self.capitalizedFirstLetter(of: expansion)
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        // Drop any placeholder fragments a processing step may have split.
        result.unicodeScalars.removeAll { scalar in
            (0xE000...0xE01F).contains(scalar.value)
        }
        return result
    }

    private static func isSentenceStart(in text: String, before index: String.Index) -> Bool {
        let preceding = text[..<index]
        guard let last = preceding.last(where: { $0 != " " && $0 != "\t" }) else { return true }
        return ".!?\n".contains(last)
    }

    private static func capitalizedFirstLetter(of expansion: String) -> String {
        guard let first = expansion.first, first.isLowercase else { return expansion }
        let firstWord = expansion.prefix { !$0.isWhitespace }
        let looksDeliberatelyCased = firstWord.dropFirst().contains(where: \.isUppercase)
            || firstWord.contains("@") || firstWord.contains("/") || firstWord.dropLast().contains(".")
        guard !looksDeliberatelyCased else { return expansion }
        return first.uppercased() + expansion.dropFirst()
    }
}
