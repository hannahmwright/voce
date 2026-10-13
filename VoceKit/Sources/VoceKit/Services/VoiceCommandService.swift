import Foundation
import os

/// Detects voice command trigger phrases in transcript text and executes their actions.
///
/// Built-in commands run on every dictation, and many of their triggers are
/// ordinary English words ("period", "space", "colon", "delete that"). Matching
/// is therefore conservative so ordinary prose passes through unchanged:
///
/// - Rarely-natural triggers ("comma", "question mark", "new paragraph", …) fire
///   anywhere, unless they are clearly used as a noun ("a comma", "the new line
///   of products").
/// - Ambiguous common-noun triggers ("period", "colon", "dash", "space") only
///   fire at the end of the utterance, immediately before another command, or
///   when the recognizer already set them off with punctuation
///   ("…how are you, period."). They never fire mid-sentence
///   ("The trial period ended yesterday.").
/// - Deletion commands ("delete that", "scratch that") only fire as the final
///   phrase of the utterance or as a stand-alone sentence ("Scratch that."), and
///   not when grammatically part of a sentence ("Please delete that.").
///
/// Custom (non built-in) insert commands keep the legacy behaviour of firing
/// wherever their trigger appears as a whole phrase.
///
/// All matching is done in a single pass on the original text; replacements are
/// then applied using consistent UTF-16 offsets.
public final class VoiceCommandService: Sendable {
    private struct Matcher: Sendable {
        var regex: NSRegularExpression
        /// Enabled commands keyed by normalized trigger (lowercased, single-spaced).
        var commandsByTrigger: [String: VoiceCommand]
    }

    private enum Placement: Sendable {
        /// Fire wherever the trigger appears (subject to noun guards).
        case anywhere
        /// Fire only at the end, before another command, or when set off by punctuation.
        case ambiguous(firesAtEnd: Bool)
        /// Delete the preceding sentence; only as a final phrase or stand-alone sentence.
        case deletion
        /// Custom insert command: legacy "fire everywhere" semantics.
        case custom
    }

    private struct Candidate {
        var range: NSRange
        var command: VoiceCommand
        var trigger: String
        var fires = false
    }

    private let matcher = OSAllocatedUnfairLock<Matcher?>(initialState: nil)

    public init(commands: [VoiceCommand] = []) {
        update(commands: commands)
    }

    public func update(commands newCommands: [VoiceCommand]) {
        var commandsByTrigger: [String: VoiceCommand] = [:]
        for command in newCommands where command.isEnabled {
            let key = Self.normalizedTrigger(command.trigger)
            guard !key.isEmpty, commandsByTrigger[key] == nil else { continue }
            commandsByTrigger[key] = command
        }

        guard !commandsByTrigger.isEmpty else {
            matcher.withLock { $0 = nil }
            return
        }

        // Longest trigger first so the ordered alternation prefers longer phrases
        // ("exclamation point" over a hypothetical "exclamation").
        let alternatives = commandsByTrigger.keys
            .sorted { lhs, rhs in lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs }
            .map { trigger in
                trigger
                    .split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            .joined(separator: "|")
        let pattern = TextMatching.termStartBoundary + "(?:" + alternatives + ")" + TextMatching.termEndBoundary
        let compiled = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            .map { [commandsByTrigger] regex in Matcher(regex: regex, commandsByTrigger: commandsByTrigger) }
        matcher.withLock { $0 = compiled }
    }

    /// Processes the given text, replacing voice command triggers with their output.
    /// Returns `text` unchanged when no command fires.
    public func apply(to text: String) -> String {
        guard let matcher = matcher.withLock({ $0 }), !text.isEmpty else { return text }

        let nsText = text as NSString
        let matches = matcher.regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var candidates: [Candidate] = matches.compactMap { match in
            let trigger = Self.normalizedTrigger(nsText.substring(with: match.range))
            guard let command = matcher.commandsByTrigger[trigger] else { return nil }
            return Candidate(range: match.range, command: command, trigger: trigger)
        }
        guard !candidates.isEmpty else { return text }

        for index in candidates.indices {
            let next = index + 1 < candidates.count ? candidates[index + 1] : nil
            candidates[index].fires = shouldFire(candidates[index], next: next, in: nsText)
        }
        guard candidates.contains(where: \.fires) else { return text }

        let edits = buildEdits(for: candidates, in: nsText)
        guard !edits.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for edit in edits {
            result += nsText.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            result += edit.replacement
            cursor = edit.range.location + edit.range.length
        }
        result += nsText.substring(from: cursor)
        return Self.tidyWhitespace(result)
    }

    // MARK: - Eligibility

    private func shouldFire(_ candidate: Candidate, next: Candidate?, in text: NSString) -> Bool {
        let context = MatchContext(range: candidate.range, in: text)

        switch placement(for: candidate.command, trigger: candidate.trigger) {
        case .custom:
            return true

        case .anywhere:
            return !isUsedAsNoun(candidate.trigger, context: context, ambiguous: false)

        case .ambiguous(let firesAtEnd):
            guard !isUsedAsNoun(candidate.trigger, context: context, ambiguous: true) else { return false }
            if firesAtEnd, context.isAtEnd { return true }
            // "…end of sentence period new paragraph…"
            if let next, isAdjacent(candidate.range, to: next.range, in: text) { return true }
            return context.isPrecededByPunctuation && (context.isFollowedByPunctuation || context.isAtEnd)

        case .deletion:
            if context.isAtEnd {
                // "Can you delete that?" is a question, not a command.
                guard !context.trailingText.contains("?") else { return false }
                if let previous = context.previousWord, Self.deletionGuardWords.contains(previous) {
                    return false
                }
                return true
            }
            // Stand-alone sentence mid-utterance: "Hello world. Scratch that. Goodbye."
            return context.isAtSentenceStart && context.isFollowedBySentenceEnd
        }
    }

    private func placement(for command: VoiceCommand, trigger: String) -> Placement {
        if case .deletePrevious = command.action {
            return .deletion
        }
        guard command.isBuiltIn else { return .custom }
        if Self.ambiguousTriggersFiringAtEnd.contains(trigger) {
            return .ambiguous(firesAtEnd: true)
        }
        if Self.ambiguousTriggersNotFiringAtEnd.contains(trigger) {
            return .ambiguous(firesAtEnd: false)
        }
        return .anywhere
    }

    private func isUsedAsNoun(_ trigger: String, context: MatchContext, ambiguous: Bool) -> Bool {
        if context.nextWord == "of" {
            // "a period of time", "a dash of salt", "a new line of products"
            return true
        }
        guard let previous = context.previousWord else { return false }
        if Self.articleGuardWords.contains(previous) { return true }
        if ambiguous, Self.ambiguousGuardWords.contains(previous) { return true }
        return Self.triggerSpecificGuardWords[trigger]?.contains(previous) ?? false
    }

    private func isAdjacent(_ lhs: NSRange, to rhs: NSRange, in text: NSString) -> Bool {
        let gapStart = lhs.location + lhs.length
        guard rhs.location >= gapStart else { return false }
        let gap = text.substring(with: NSRange(location: gapStart, length: rhs.location - gapStart))
        return gap.unicodeScalars.allSatisfy { Self.softPunctuation.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    // MARK: - Edits

    private struct Edit {
        var range: NSRange
        var replacement: String
    }

    private func buildEdits(for candidates: [Candidate], in text: NSString) -> [Edit] {
        // Sentence-ending insertions act as boundaries for later deletions:
        // "Hello world question mark goodbye scratch that" deletes only "goodbye".
        let boundaryRanges: [NSRange] = candidates.compactMap { candidate in
            guard candidate.fires, case .insertText(let replacement) = candidate.command.action,
                  replacement.contains(where: { ".?!\n".contains($0) }) else { return nil }
            return candidate.range
        }

        // Resolve deletions first; any candidate inside a deleted span is dropped.
        var deletionSpans: [NSRange] = []
        for candidate in candidates where candidate.fires {
            guard case .deletePrevious = candidate.command.action else { continue }
            let start = sentenceStart(before: candidate.range.location, in: text, boundaries: boundaryRanges)
            var end = candidate.range.location + candidate.range.length
            while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)),
                  Self.softPunctuation.contains(scalar) || scalar == "!" || scalar == "?" {
                end += 1
            }
            deletionSpans.append(NSRange(location: start, length: end - start))
        }
        deletionSpans = Self.mergedRanges(deletionSpans)

        var edits: [Edit] = deletionSpans.map { Edit(range: $0, replacement: "") }

        for (index, candidate) in candidates.enumerated() where candidate.fires {
            guard case .insertText(let replacement) = candidate.command.action else { continue }
            if deletionSpans.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) {
                continue
            }

            // Absorb surrounding whitespace/punctuation without crossing into
            // neighbouring candidates or deletion spans.
            let previousLimit = max(
                index > 0 ? candidates[index - 1].range.location + candidates[index - 1].range.length : 0,
                deletionSpans.filter { $0.location + $0.length <= candidate.range.location }
                    .map { $0.location + $0.length }.max() ?? 0
            )
            let nextLimit = min(
                index + 1 < candidates.count ? candidates[index + 1].range.location : text.length,
                deletionSpans.filter { $0.location >= candidate.range.location + candidate.range.length }
                    .map(\.location).min() ?? text.length
            )
            edits.append(
                insertionEdit(
                    replacement: replacement,
                    isBuiltIn: candidate.command.isBuiltIn,
                    range: candidate.range,
                    previousLimit: previousLimit,
                    nextLimit: nextLimit,
                    in: text
                )
            )
        }

        edits.sort { $0.range.location < $1.range.location }
        // Drop any edit that would overlap a previous one (defensive; ranges are
        // constructed not to overlap).
        var nonOverlapping: [Edit] = []
        var lastEnd = 0
        for edit in edits where edit.range.location >= lastEnd {
            nonOverlapping.append(edit)
            lastEnd = edit.range.location + edit.range.length
        }
        return nonOverlapping
    }

    private func insertionEdit(
        replacement: String,
        isBuiltIn: Bool,
        range: NSRange,
        previousLimit: Int,
        nextLimit: Int,
        in text: NSString
    ) -> Edit {
        var start = range.location
        var end = range.location + range.length

        func absorbBefore(_ set: CharacterSet) {
            while start > previousLimit, let scalar = Unicode.Scalar(text.character(at: start - 1)), set.contains(scalar) {
                start -= 1
            }
        }
        func absorbAfter(_ set: CharacterSet) {
            while end < nextLimit, let scalar = Unicode.Scalar(text.character(at: end)), set.contains(scalar) {
                end += 1
            }
        }

        let horizontalSpace = CharacterSet.whitespaces
        let spaceAndSoftPunctuation = horizontalSpace.union(Self.softPunctuation)

        switch Self.insertionKind(for: replacement, isBuiltIn: isBuiltIn) {
        case .closingPunctuation:
            // "how are you, period." → "how are you."
            absorbBefore(spaceAndSoftPunctuation)
            absorbAfter(Self.softPunctuation)
        case .closingBracket:
            absorbBefore(horizontalSpace)
        case .openingBracket:
            absorbAfter(horizontalSpace)
        case .lineBreak:
            absorbBefore(horizontalSpace)
            absorbAfter(spaceAndSoftPunctuation)
            absorbAfter(horizontalSpace)
        case .joiner:
            // "well hyphen known" → "well-known"; dash replacement carries its own spaces.
            absorbBefore(horizontalSpace.union(CharacterSet(charactersIn: ",")))
            absorbAfter(horizontalSpace.union(CharacterSet(charactersIn: ",")))
        case .legacyPunctuation:
            // Custom single-character punctuation: drop one preceding space.
            if start > previousLimit, text.character(at: start - 1) == 0x20 {
                start -= 1
            }
        case .plain:
            break
        }

        return Edit(range: NSRange(location: start, length: end - start), replacement: replacement)
    }

    private enum InsertionKind {
        case closingPunctuation
        case closingBracket
        case openingBracket
        case lineBreak
        case joiner
        case legacyPunctuation
        case plain
    }

    private static func insertionKind(for replacement: String, isBuiltIn: Bool) -> InsertionKind {
        guard isBuiltIn else {
            if replacement.count == 1, let first = replacement.first, !first.isLetter, !first.isNumber {
                return .legacyPunctuation
            }
            return .plain
        }
        switch replacement {
        case ".", ",", "?", "!", ":", ";", "\u{2026}":
            return .closingPunctuation
        case "\u{201D}", ")":
            return .closingBracket
        case "\u{201C}", "(":
            return .openingBracket
        case "\n", "\n\n", "\t":
            return .lineBreak
        case "-", " \u{2014} ", " ":
            return .joiner
        default:
            return .plain
        }
    }

    /// UTF-16 offset where the sentence containing `location` begins.
    ///
    /// If the trigger starts a new sentence ("Hello world. Scratch that."), the
    /// sentence before it is the one deleted.
    private func sentenceStart(before location: Int, in text: NSString, boundaries: [NSRange]) -> Int {
        func isEnder(_ index: Int) -> Bool {
            if boundaries.contains(where: { NSLocationInRange(index, $0) }) { return true }
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return Self.sentenceEnders.contains(scalar)
        }
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespaces.contains(scalar)
        }

        var index = location - 1
        // Skip whitespace and the terminator of the sentence being deleted.
        while index >= 0, isSpace(index) || isEnder(index) {
            index -= 1
        }
        // Walk back to the previous sentence terminator.
        while index >= 0, !isEnder(index) {
            index -= 1
        }
        return index + 1
    }

    // MARK: - Helpers

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func normalizedTrigger(_ trigger: String) -> String {
        trigger
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.replacingOccurrences(of: " \n", with: "\n")
        result = result.replacingOccurrences(of: "\n ", with: "\n")
        // Spacing before inserted punctuation is handled per edit, so user text
        // elsewhere (e.g. "3 : 1") is not rewritten here.
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let softPunctuation = CharacterSet(charactersIn: ",.;:")
    private static let sentenceEnders = CharacterSet(charactersIn: ".!?\n")

    /// Ambiguous common nouns: never fire mid-sentence.
    private static let ambiguousTriggersFiringAtEnd: Set<String> = ["period", "colon", "dash"]
    /// "space" at the end of an utterance would only insert trailing whitespace,
    /// so it only fires before another command or when set off by punctuation.
    private static let ambiguousTriggersNotFiringAtEnd: Set<String> = ["space"]

    /// Words that, directly before a trigger, mark it as a noun ("a comma").
    private static let articleGuardWords: Set<String> = [
        "a", "an", "the", "my", "your", "our", "their", "his", "her", "its",
        "every", "each", "another", "no",
    ]

    /// Extra noun markers for ambiguous common-noun triggers.
    private static let ambiguousGuardWords: Set<String> = [
        "this", "that", "these", "those", "some", "any", "more", "less", "much", "enough",
        "extra", "same", "whole", "entire", "one", "per", "what", "which", "whose",
        "in", "into", "of", "for", "from", "through", "during", "over", "within", "without",
        "at", "on", "by", "with", "short", "long", "brief", "given", "certain", "little",
        "small", "big", "huge", "free", "open", "empty", "white", "blank", "outer",
        "difficult", "hard", "tough", "busy", "quiet", "set", "fixed", "limited",
        "previous", "prior", "following", "current", "recent", "similar", "specific",
    ]

    private static let triggerSpecificGuardWords: [String: Set<String>] = [
        "period": [
            "trial", "waiting", "grace", "time", "cooling", "rest", "notice", "probation",
            "probationary", "holiday", "transition", "transitional", "test", "testing",
            "warranty", "introductory", "sample", "study", "school", "class", "lunch",
            "billing", "reporting", "review", "comment", "evaluation", "adjustment",
            "payment", "pay", "vesting", "lockup", "election", "menstrual", "historical",
            "initial", "final", "extended", "specified", "defined", "recovery", "blackout",
            "renewal", "contract", "fiscal", "accounting", "tax", "peak", "sprint", "release",
            "retention", "interim", "honeymoon", "dark", "early", "late", "modern", "colonial",
            "victorian", "medieval", "classical", "baroque", "romantic", "critical", "growth",
            "incubation", "observation", "trading", "measurement", "orbital", "free",
        ],
        "space": [
            "disk", "storage", "memory", "office", "parking", "living", "work", "working",
            "personal", "safe", "deep", "shared", "crawl", "attic", "negative", "name",
            "address", "table", "swap", "drive", "breathing", "green", "retail", "event",
            "floor", "desk", "closet", "head", "user", "kernel", "color", "colour", "screen",
            "ad", "cyber", "air", "commercial", "public", "private", "creative", "available",
            "physical", "virtual", "outer", "need", "needs", "needed",
        ],
        "dash": ["hundred", "yard", "meter", "metre", "mad", "em", "en", "dot", "sprint", "100", "50", "40"],
        "colon": ["sigmoid", "transverse", "ascending", "descending", "healthy", "double"],
        "hyphen": ["soft", "hard", "double", "breaking"],
        "comma": ["oxford", "serial", "inverted"],
        "question mark": ["big", "huge", "giant", "real", "serious", "major"],
        "new line": ["this", "that", "these", "those", "entire", "whole", "brand", "first", "next", "last", "blank", "empty", "some", "any"],
        "newline": ["this", "that", "these", "those", "entire", "whole", "first", "next", "last", "blank", "empty", "some", "any"],
        "new paragraph": ["this", "that", "these", "those", "entire", "whole", "brand", "first", "next", "last", "some", "any"],
    ]

    /// Words that, directly before "delete that"/"scratch that" at the end of an
    /// utterance, make it part of a sentence ("Please delete that.").
    private static let deletionGuardWords: Set<String> = [
        "to", "please", "can", "could", "would", "will", "should", "must", "might", "may",
        "shall", "i", "you", "we", "they", "he", "she", "it", "and", "or", "but", "then",
        "not", "never", "also", "just", "let's", "lets", "let", "don't", "didn't",
        "doesn't", "won't", "can't", "couldn't", "shouldn't", "wouldn't", "i'll", "we'll",
        "you'll", "they'll", "he'll", "she'll", "i'd", "we'd", "you'd", "they'd", "did",
        "do", "does", "so", "go", "gonna", "wanna", "always", "simply", "who", "which",
        "please", "pls", "plz",
    ]
}

/// Lexical context around a candidate trigger match.
private struct MatchContext {
    /// Word immediately before the trigger, when separated only by spaces.
    var previousWord: String?
    /// Word immediately after the trigger, when separated only by spaces.
    var nextWord: String?
    /// Only whitespace and punctuation follow the trigger.
    var isAtEnd: Bool
    /// The text after the trigger (used to inspect trailing punctuation).
    var trailingText: String
    /// The nearest non-space character before the trigger is punctuation.
    var isPrecededByPunctuation: Bool
    /// The next non-space character after the trigger is punctuation.
    var isFollowedByPunctuation: Bool
    /// Trigger begins the text or follows a sentence terminator.
    var isAtSentenceStart: Bool
    /// The trigger is followed directly by a sentence terminator.
    var isFollowedBySentenceEnd: Bool

    init(range: NSRange, in text: NSString) {
        let before = text.substring(to: range.location)
        let after = text.substring(from: range.location + range.length)
        trailingText = after

        let beforeTrimmed = before.trimmingTrailingHorizontalWhitespace()
        let lastBefore = beforeTrimmed.last
        isPrecededByPunctuation = lastBefore.map { $0.isPunctuation } ?? false
        isAtSentenceStart = lastBefore.map { ".!?\n".contains($0) } ?? true
        previousWord = (lastBefore.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" } ?? false)
            ? WordTokenizer.words(in: String(beforeTrimmed.suffix(64))).last
            : nil

        let afterTrimmed = after.drop(while: { $0 == " " || $0 == "\t" })
        let firstAfter = afterTrimmed.first
        isFollowedByPunctuation = firstAfter.map { $0.isPunctuation } ?? false
        isFollowedBySentenceEnd = firstAfter.map { ".!?\n".contains($0) } ?? false
        isAtEnd = after.allSatisfy { $0.isWhitespace || $0.isPunctuation }
        nextWord = (firstAfter.map { $0.isLetter || $0.isNumber } ?? false)
            ? WordTokenizer.words(in: String(afterTrimmed.prefix(64))).first
            : nil
    }
}

private extension String {
    func trimmingTrailingHorizontalWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous] == " " || self[previous] == "\t" else { break }
            end = previous
        }
        return self[..<end]
    }
}
