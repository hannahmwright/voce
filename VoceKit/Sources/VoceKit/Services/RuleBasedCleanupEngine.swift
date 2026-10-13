import Foundation

public struct RuleBasedCleanupEngine: CleanupEngine, Sendable {
    enum AutoListKind: Sendable {
        case bullets
        case numbered
    }

    /// Word frequency data from the learning engine, used to bias candidate ranking
    /// toward the user's familiar vocabulary.
    public var wordFrequencies: [String: Int]

    public init(wordFrequencies: [String: Int] = [:]) {
        self.wordFrequencies = wordFrequencies
    }

    public func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        let normalizedRaw = RawTranscript(
            text: ConsecutivePhraseDeduplicator.collapse(raw.text),
            segments: raw.segments,
            durationMS: raw.durationMS
        )
        let generator = RuleBasedCleanupCandidateGenerator()
        let candidates = try await generator.generateCandidates(
            raw: normalizedRaw,
            profile: profile,
            lexicon: lexicon
        )
        let ranker = LocalCleanupRanker(wordFrequencies: wordFrequencies)
        // Score against the lexicon-corrected raw text so a correction that
        // merges words ("open ai" → "OpenAI") is not counted as dropped content.
        let lexiconCorrectedRaw = applyLexicon(text: normalizedRaw.text, lexicon: lexicon).text
        let best = ranker.bestCandidate(
            rawText: lexiconCorrectedRaw,
            candidates: candidates,
            profile: profile
        )

        return CleanTranscript(
            text: best.text,
            edits: best.appliedEdits,
            removedFillers: best.removedFillers,
            uncertaintyFlags: []
        )
    }

    func buildCandidate(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        rulePathID: String
    ) -> CleanupCandidate {
        var text = ConsecutivePhraseDeduplicator.collapse(raw.text)
        var edits: [TranscriptEdit] = []
        var removedFillers: [String] = []

        let fillerResult = removeFillers(from: text, policy: profile.fillerPolicy)
        text = fillerResult.text
        removedFillers = fillerResult.removed
        edits.append(contentsOf: fillerResult.edits)

        let lexiconResult = applyLexicon(text: text, lexicon: lexicon)
        text = lexiconResult.text
        edits.append(contentsOf: lexiconResult.edits)

        let structureResult = applyStructure(text: text, mode: profile.structureMode)
        text = structureResult.text
        edits.append(contentsOf: structureResult.edits)

        return CleanupCandidate(
            text: text,
            appliedEdits: edits,
            removedFillers: removedFillers,
            rulePathID: rulePathID
        )
    }

    // MARK: - Precompiled Regexes

    /// Words that always indicate filler regardless of context.
    private static let unconditionalFillerRegexes: [String: NSRegularExpression] = {
        let fillers = ["um", "uh"]
        var dict: [String: NSRegularExpression] = [:]
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            let pattern = "(?i)(?:\\s|^)\(escaped)(?=\\s|[,.!?]|$)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                dict[filler] = regex
            }
        }
        return dict
    }()

    /// Context-aware filler patterns that use negative lookahead to preserve
    /// intentional usage. Each filler word is only stripped when NOT followed
    /// by words that indicate meaningful use.
    private static let contextAwareFillerRegexes: [String: NSRegularExpression] = {
        // "you know" is intentional before articles, pronouns, wh-words, "how", "if", "about"
        // e.g. "you know the answer", "you know what I mean", "you know how it works"
        let youKnowSafe = "(?:the|a|an|that|this|those|these|what|who|where|when|why|which|how|if|about|my|his|her|our|your|their|it)"
        // "I mean" is intentional before pronouns, articles, "that", "it", "to"
        // e.g. "I mean it", "I mean the one on the left", "I mean to say"
        let iMeanSafe = "(?:it|that|this|the|a|an|to|what|my|his|her|our|your|their|we|they|he|she|you)"
        // "sort of" / "kind of" is intentional before articles, nouns (thing/person/etc)
        // e.g. "kind of dog", "sort of a problem" — but "it's kind of weird" is filler
        let ofSafe = "(?:a|an|the|thing|person|way|place|like)"
        // "basically" is almost always filler in speech, but preserve before a comma
        // or when it starts a clause that explains something
        let basicallySafe = "(?:the|a|an|it|what)"

        let specs: [(String, String)] = [
            ("you know", "(?i)(?:\\s|^)you know(?!\\s+\(youKnowSafe)(?:\\s|[,.!?]|$))(?=\\s|[,.!?]|$)"),
            // Preserve meaning-bearing phrases such as "that's what I mean" and
            // "you know what I mean" by refusing to treat "I mean" as filler
            // when it is preceded by "what ".
            ("i mean", "(?i)(?:\\s|^)(?<!what\\s)i mean(?!\\s+\(iMeanSafe)(?:\\s|[,.!?]|$))(?=\\s|[,.!?]|$)"),
            ("sort of", "(?i)(?:\\s|^)sort of(?!\\s+\(ofSafe)(?:\\s|[,.!?]|$))(?=\\s|[,.!?]|$)"),
            ("kind of", "(?i)(?:\\s|^)kind of(?!\\s+\(ofSafe)(?:\\s|[,.!?]|$))(?=\\s|[,.!?]|$)"),
            ("basically", "(?i)(?:\\s|^)basically(?!\\s+\(basicallySafe)(?:\\s|[,.!?]|$))(?=\\s|[,.!?]|$)"),
        ]

        var dict: [String: NSRegularExpression] = [:]
        for (filler, pattern) in specs {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                dict[filler] = regex
            }
        }
        return dict
    }()

    /// "like" patterns — only strip comma-delimited filler "like" and sentence-initial "like".
    /// Preserve meaningful "like" after verbs (is/are/was/were/looks/sounds/feels/seems/would/could).
    private static let likePatterns: [(regex: NSRegularExpression, replacement: String)] = {
        let specs: [(pattern: String, replacement: String)] = [
            // Sentence-initial filler: "Like, we should go"
            ("(?i)(^|[.!?]\\s+)like,\\s+", "$1"),
            // Comma-wrapped filler: "it was, like, really big"
            ("(?i),\\s*like,\\s*", ", ")
        ]
        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { return nil }
            return (regex, spec.replacement)
        }
    }()

    private static let whitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\s+")
    }()

    // MARK: - Filler Removal

    private func removeFillers(from text: String, policy: FillerPolicy) -> (text: String, removed: [String], edits: [TranscriptEdit]) {
        guard policy != .minimal else {
            return (text, [], [])
        }

        // Unconditional fillers (um, uh) are always safe to remove.
        let unconditionalFillers = ["um", "uh"]
        // Context-aware fillers only removed when not followed by safe-context words.
        let balancedContextFillers: [String] = ["you know"]
        let aggressiveContextFillers = balancedContextFillers + ["i mean", "basically", "sort of", "kind of"]
        let contextFillers = policy == .balanced ? balancedContextFillers : aggressiveContextFillers

        var updated = text
        var removed: [String] = []
        var edits: [TranscriptEdit] = []

        // Remove unconditional fillers.
        for filler in unconditionalFillers {
            guard let regex = Self.unconditionalFillerRegexes[filler] else { continue }
            let range = NSRange(updated.startIndex..., in: updated)
            let count = regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: " ")
                removed.append(contentsOf: Array(repeating: filler, count: count))
                edits.append(TranscriptEdit(kind: .fillerRemoval, from: filler, to: ""))
            }
        }

        // Remove context-aware fillers (only when not followed by meaningful words).
        for filler in contextFillers {
            guard let regex = Self.contextAwareFillerRegexes[filler] else { continue }
            let range = NSRange(updated.startIndex..., in: updated)
            let count = regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: " ")
                removed.append(contentsOf: Array(repeating: filler, count: count))
                edits.append(TranscriptEdit(kind: .fillerRemoval, from: filler, to: ""))
            }
        }

        let likeRemovals = removeInterjectionalLike(from: updated)
        updated = likeRemovals.text
        if likeRemovals.count > 0 {
            removed.append(contentsOf: Array(repeating: "like", count: likeRemovals.count))
            edits.append(TranscriptEdit(kind: .fillerRemoval, from: "like", to: ""))
        }

        if !removed.isEmpty {
            updated = tidyPunctuationAfterRemoval(updated)
        }
        updated = collapseWhitespace(updated)
        return (updated, removed, edits)
    }

    /// Repairs punctuation left orphaned by filler removal:
    /// "So, um, I think" → "So, , I think" → "So, I think".
    private static let orphanPunctuationRules: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // Space before punctuation: "So , I" → "So, I" (not ".net", ":)")
            (#"[ \t]+([,.!?;:])(?=\s|[,.!?;:]|$)"#, "$1"),
            // Repeated commas: "So,, I" → "So, I"
            (#",(?:[ \t]*,)+"#, ","),
            // Comma before terminal punctuation: "think,." → "think."
            (#",[ \t]*([.!?;:])"#, "$1"),
            // Comma at the start of the text: ", I think" → "I think"
            (#"^[ \t]*[,;:][ \t]*"#, ""),
            // Comma right after a sentence end: "Yes., okay" → "Yes. okay"
            (#"([.!?])[ \t]*,[ \t]*"#, "$1 "),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
            return (regex, template)
        }
    }()

    private func tidyPunctuationAfterRemoval(_ text: String) -> String {
        var updated = text
        for rule in Self.orphanPunctuationRules {
            let range = NSRange(updated.startIndex..., in: updated)
            updated = rule.regex.stringByReplacingMatches(in: updated, range: range, withTemplate: rule.template)
        }
        return updated
    }

    private func removeInterjectionalLike(from text: String) -> (text: String, count: Int) {
        var updated = text
        var removedCount = 0

        for item in Self.likePatterns {
            let range = NSRange(updated.startIndex..., in: updated)
            let count = item.regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                updated = item.regex.stringByReplacingMatches(in: updated, range: range, withTemplate: item.replacement)
                removedCount += count
            }
        }

        return (updated, removedCount)
    }

    // MARK: - Lexicon

    private static let lexiconRegexCache = RegexCache()

    func applyLexicon(text: String, lexicon: PersonalLexicon) -> (text: String, edits: [TranscriptEdit]) {
        var updated = text
        var edits: [TranscriptEdit] = []

        // Lexicon entries are already sorted longest-first by the PersonalLexicon invariant.
        for entry in lexicon.entries {
            guard !entry.term.isEmpty,
                  let regex = TextMatching.wholeTermRegex(for: entry.term, cache: Self.lexiconRegexCache)
            else { continue }
            let range = NSRange(updated.startIndex..., in: updated)
            let count = regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                let safeReplacement = NSRegularExpression.escapedTemplate(for: entry.preferred)
                updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: safeReplacement)
                edits.append(TranscriptEdit(kind: .lexiconCorrection, from: entry.term, to: entry.preferred))
            }
        }

        return (updated, edits)
    }

    // MARK: - Structure

    private func applyStructure(text: String, mode: StructureMode) -> (text: String, edits: [TranscriptEdit]) {
        switch mode {
        case .natural, .command:
            if let automatic = applyAutomaticListFormattingIfNeeded(to: text) {
                return automatic
            }
            return (text, [])
        case .paragraph:
            if let automatic = applyAutomaticListFormattingIfNeeded(to: text) {
                return automatic
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (capitalizedSentence(trimmed), [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "paragraph")])
        case .bullets:
            let clauses = splitIntoClauses(text)
            let bulletText = clauses.map { "- \($0)" }.joined(separator: "\n")
            return (bulletText, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "bullets")])
        case .email:
            let body = capitalizedSentence(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let email = "Hi,\n\n\(body)\n\nThanks,"
            return (email, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "email")])
        }
    }

    private func applyAutomaticListFormattingIfNeeded(to text: String) -> (text: String, edits: [TranscriptEdit])? {
        if let explicit = explicitListRewrite(from: text) {
            return explicit
        }

        if let ordinal = ordinalListRewrite(from: text) {
            return ordinal
        }

        return nil
    }

    private func explicitListRewrite(from text: String) -> (text: String, edits: [TranscriptEdit])? {
        guard let cue = Self.explicitListCue(in: text) else { return nil }
        let items = splitListItems(cue.remainder)
        guard items.count >= 2 else { return nil }
        switch cue.kind {
        case .bullets:
            return formatList(items: items, kind: .bullets, source: "auto-bullets")
        case .numbered:
            return formatList(items: items, kind: .numbered, source: "auto-numbered")
        }
    }

    /// Spoken list cues. "bullet list"/"numbered list" may be followed directly
    /// by the items; the noun-like "bullet points"/"numbered items" require a
    /// colon so prose such as "Bullet points are great, but…" is left alone.
    private static let explicitListCueRegexes: [(regex: NSRegularExpression, kind: AutoListKind)] = {
        let specs: [(String, AutoListKind)] = [
            (#"^\s*(?:bullet(?:ed)? list)\s*:?\s+"#, .bullets),
            (#"^\s*(?:bullet points?)\s*:\s*"#, .bullets),
            (#"^\s*(?:numbered list|number list)\s*:?\s+"#, .numbered),
            (#"^\s*(?:numbered points|numbered items)\s*:\s*"#, .numbered),
        ]
        return specs.compactMap { pattern, kind in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, kind)
        }
    }()

    /// Words that, right after a colon-less cue, show it is the sentence subject
    /// ("Bullet list was too long, so I cut it.") rather than a dictated list.
    private static let listCueProseFollowers: Set<String> = [
        "is", "are", "was", "were", "has", "have", "had", "looks", "looked", "seems", "seemed",
        "will", "would", "should", "could", "can", "might", "must", "does", "did", "that",
        "which", "of", "in", "on", "for", "with", "needs", "needed", "items",
    ]

    static func explicitListCue(in text: String) -> (kind: AutoListKind, remainder: String)? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for cue in explicitListCueRegexes {
            guard let match = cue.regex.firstMatch(in: text, range: fullRange) else { continue }
            let remainder = nsText.substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matchedCue = nsText.substring(with: match.range)
            if !matchedCue.contains(":"),
               let firstWord = WordTokenizer.words(in: String(remainder.prefix(32))).first,
               listCueProseFollowers.contains(firstWord) {
                return nil
            }
            guard !remainder.isEmpty else { return nil }
            return (cue.kind, remainder)
        }
        return nil
    }

    private func ordinalListRewrite(from text: String) -> (text: String, edits: [TranscriptEdit])? {
        guard let items = Self.ordinalListItems(from: text) else { return nil }
        return formatList(items: items, kind: .numbered, source: "auto-numbered")
    }

    /// Ordinal list patterns ("first … second … [third …]"). An ordinal only
    /// starts an item when it is not part of a phrase: never "first of all",
    /// "second of", "a second", "the second", "in a second", and so on.
    private static let ordinalListRegexes: [NSRegularExpression] = {
        let notPhrase = #"(?!\s+of\b)"#
        let notAfterDeterminer = #"(?<!\b(?:a|an|the|one|per|each|every|this|that|its|in|at|for|wait|just|split)\s)"#
        func ordinal(_ word: String) -> String { notAfterDeterminer + word + notPhrase }

        let base = #"(?is)^\s*first"# + notPhrase + #"\s+(.+?)\s+"# + ordinal("second") + #"\s+(.+?)"#
        let patterns = [
            base + #"\s+"# + ordinal("third") + #"\s+(.+?)\s*[.!?]?\s*$"#,
            base + #"\s*[.!?]?\s*$"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func ordinalListItems(from text: String) -> [String]? {
        let fullRange = NSRange(text.startIndex..., in: text)
        for regex in ordinalListRegexes {
            guard let match = regex.firstMatch(in: text, range: fullRange) else { continue }

            let items = (1..<match.numberOfRanges)
                .compactMap { index -> Range<String.Index>? in
                    let range = match.range(at: index)
                    guard range.location != NSNotFound else { return nil }
                    return Range(range, in: text)
                }
                .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !$0.contains("\n") }

            guard items.count >= 2 else { continue }
            guard items.allSatisfy({ $0.split(whereSeparator: \.isWhitespace).count <= 12 }) else { continue }
            return items
        }
        return nil
    }


    private func splitListItems(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\n", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: ",;\n")
        let pieces = normalized.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if pieces.count >= 2 {
            return pieces.map(capitalizedSentence)
        }

        return splitIntoClauses(normalized)
    }

    private func formatList(items: [String], kind: AutoListKind, source: String) -> (text: String, edits: [TranscriptEdit]) {
        let formattedItems = items.map(capitalizedSentence)
        let text: String
        switch kind {
        case .bullets:
            text = formattedItems.map { "- \($0)" }.joined(separator: "\n")
        case .numbered:
            text = formattedItems.enumerated().map { index, item in
                "\(index + 1). \(item)"
            }.joined(separator: "\n")
        }

        return (
            text,
            [TranscriptEdit(kind: .structureRewrite, from: "raw", to: source)]
        )
    }

    private func splitIntoClauses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",.;")
        let pieces = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if pieces.isEmpty {
            return [capitalizedSentence(text)]
        }

        return pieces.map(capitalizedSentence)
    }

    private func capitalizedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private func collapseWhitespace(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let collapsed = Self.whitespaceRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
