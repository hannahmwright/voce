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
        return protected.restore(in: protected.text)
    }

    /// Replaces snippet triggers with opaque placeholders so the text can go
    /// through cleanup, voice commands and cloud refinement without the
    /// triggers (or their expansions) being altered. Call
    /// ``SnippetProtectedText/restore(in:capitalizingAtTextStart:)`` on the
    /// processed text to insert the expansions.
    public func protect(_ text: String, appContext: AppContext?) -> SnippetProtectedText {
        guard !text.isEmpty, let compiled = compiled(for: appContext?.bundleIdentifier) else {
            return SnippetProtectedText(text: text, expansions: [])
        }

        let nsText = text as NSString
        let matches = compiled.regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return SnippetProtectedText(text: text, expansions: []) }

        var result = ""
        var cursor = 0
        var expansions: [String] = []
        for match in matches {
            let matchedTrigger = Self.normalizedTrigger(nsText.substring(with: match.range))
            guard let expansion = compiled.expansionsByTrigger[matchedTrigger] else { continue }
            let placeholder = SnippetProtectedText.placeholder(index: expansions.count)
            expansions.append(expansion)
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
/// Placeholders consist only of Unicode private-use characters
/// (`U+E000`, private-use "digits" `U+E010…U+E019`, `U+E001`), so no cleanup
/// step that works on letters, digits, whitespace or punctuation (filler
/// removal, lexicon, voice commands, list formatting) can match or alter them.
public struct SnippetProtectedText: Sendable, Equatable {
    /// The text with placeholders in place of snippet triggers.
    public var text: String
    /// Expansion for each placeholder, indexed by placeholder id.
    public var expansions: [String]

    public init(text: String, expansions: [String]) {
        self.text = text
        self.expansions = expansions
    }

    public var hasPlaceholders: Bool { !expansions.isEmpty }

    /// The placeholder strings, in id order.
    public var placeholders: [String] {
        expansions.indices.map(Self.placeholder(index:))
    }

    /// True when the text contains letters or digits outside placeholders,
    /// i.e. there is something for a cleanup engine to work on.
    public var hasContentOutsidePlaceholders: Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) && !Self.isPlaceholderScalar($0) }
    }

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

    static func isPlaceholderScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xE01F).contains(scalar.value)
    }

    private enum Piece {
        case text(String.UnicodeScalarView)
        case placeholder(Int)
        case malformed
    }

    /// Splits `processed` into text runs and placeholders in one left-to-right pass.
    private static func pieces(of processed: String) -> [Piece] {
        var pieces: [Piece] = []
        var run = String.UnicodeScalarView()
        var digits: [UInt32]?

        for scalar in processed.unicodeScalars {
            if var collecting = digits {
                if scalar == placeholderEnd {
                    let index = collecting.reduce(0) { $0 * 10 + Int($1) }
                    pieces.append(collecting.isEmpty ? .malformed : .placeholder(index))
                    digits = nil
                } else if (placeholderDigitBase...(placeholderDigitBase + 9)).contains(scalar.value) {
                    collecting.append(scalar.value - placeholderDigitBase)
                    digits = collecting
                } else {
                    pieces.append(.malformed)
                    digits = nil
                    if scalar == placeholderStart {
                        digits = []
                    } else if !isPlaceholderScalar(scalar) {
                        run.append(scalar)
                    }
                }
                continue
            }

            if scalar == placeholderStart {
                if !run.isEmpty {
                    pieces.append(.text(run))
                    run = String.UnicodeScalarView()
                }
                digits = []
            } else if isPlaceholderScalar(scalar) {
                pieces.append(.malformed)
            } else {
                run.append(scalar)
            }
        }
        if digits != nil {
            pieces.append(.malformed)
        }
        if !run.isEmpty {
            pieces.append(.text(run))
        }
        return pieces
    }

    /// Whether processed text (e.g. cloud refinement output) can safely receive
    /// the expansions: no placeholder is duplicated, altered or unknown.
    /// Dropping some placeholders is allowed (a self-correction may legitimately
    /// remove a snippet) as long as at least one survives; dropped
    /// placeholders are simply not restored.
    public func placeholdersAreIntact(in processed: String) -> Bool {
        var seen = Set<Int>()
        for piece in Self.pieces(of: processed) {
            switch piece {
            case .text:
                continue
            case .malformed:
                return false
            case .placeholder(let index):
                guard expansions.indices.contains(index), seen.insert(index).inserted else { return false }
            }
        }
        // Losing every placeholder suggests the engine stripped them rather
        // than resolving a self-correction, so it is treated as a failure.
        return !hasPlaceholders || !seen.isEmpty
    }

    /// Replaces placeholders in `processed` with their expansions, verbatim
    /// (line breaks and casing kept), in a single left-to-right pass.
    ///
    /// With `capitalizingAtTextStart`, an expansion that begins the whole text
    /// gets its first letter capitalized, matching what sentence-capitalizing
    /// profiles did when snippets were expanded before cleanup. Expansions
    /// whose first word looks deliberately cased (an email, URL, "iPhone") are
    /// left alone. Malformed placeholder fragments are dropped.
    public func restore(in processed: String, capitalizingAtTextStart: Bool = false) -> String {
        guard hasPlaceholders || processed.unicodeScalars.contains(where: Self.isPlaceholderScalar) else {
            return processed
        }
        var result = ""
        for piece in Self.pieces(of: processed) {
            switch piece {
            case .text(let run):
                result.unicodeScalars.append(contentsOf: run)
            case .malformed:
                continue
            case .placeholder(let index):
                guard expansions.indices.contains(index) else { continue }
                let expansion = expansions[index]
                let isAtTextStart = result.allSatisfy(\.isWhitespace)
                result += capitalizingAtTextStart && isAtTextStart
                    ? Self.capitalizedFirstLetter(of: expansion)
                    : expansion
            }
        }
        return result
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
