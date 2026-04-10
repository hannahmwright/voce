import Foundation

public struct RuleBasedCleanupEngine: CleanupEngine, Sendable {
    private enum AutoListKind {
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
        let best = ranker.bestCandidate(
            rawText: normalizedRaw.text,
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

        updated = collapseWhitespace(updated)
        return (updated, removed, edits)
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

    private func applyLexicon(text: String, lexicon: PersonalLexicon) -> (text: String, edits: [TranscriptEdit]) {
        var updated = text
        var edits: [TranscriptEdit] = []

        // Lexicon entries are already sorted longest-first by the PersonalLexicon invariant.
        for entry in lexicon.entries {
            let escaped = NSRegularExpression.escapedPattern(for: entry.term)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let bulletPrefixes = [
            "bullet list ",
            "bullet points ",
            "bulleted list ",
            "bullet point "
        ]
        let numberedPrefixes = [
            "numbered list ",
            "number list ",
            "numbered points ",
            "numbered items "
        ]

        if let prefix = bulletPrefixes.first(where: { lowered.hasPrefix($0) }) {
            let remainder = String(trimmed.dropFirst(prefix.count))
            let items = splitListItems(remainder)
            guard items.count >= 2 else { return nil }
            return formatList(items: items, kind: .bullets, source: "auto-bullets")
        }

        if let prefix = numberedPrefixes.first(where: { lowered.hasPrefix($0) }) {
            let remainder = String(trimmed.dropFirst(prefix.count))
            let items = splitListItems(remainder)
            guard items.count >= 2 else { return nil }
            return formatList(items: items, kind: .numbered, source: "auto-numbered")
        }

        return nil
    }

    private func ordinalListRewrite(from text: String) -> (text: String, edits: [TranscriptEdit])? {
        let patterns = [
            ("first", "second", "third"),
            ("first", "second", nil),
        ]

        let fullRange = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            let regexPattern = ordinalPattern(first: pattern.0, second: pattern.1, third: pattern.2)
            guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
                continue
            }

            guard let match = regex.firstMatch(in: text, range: fullRange) else { continue }

            let itemRanges = (1..<match.numberOfRanges).compactMap { index -> Range<String.Index>? in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
                    return nil
                }
                return swiftRange
            }

            let items = itemRanges
                .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !$0.contains("\n") }

            guard items.count >= 2 else { continue }
            guard items.allSatisfy({ $0.split(whereSeparator: \.isWhitespace).count <= 12 }) else { continue }

            return formatList(items: items, kind: .numbered, source: "auto-numbered")
        }

        return nil
    }

    private func ordinalPattern(first: String, second: String, third: String?) -> String {
        let base = #"(?is)^\s*"# +
            first + #"\s+(.+?)\s+"# +
            second + #"\s+(.+?)"#
        if let third {
            return base + #"\s+"# + third + #"\s+(.+?)\s*[.!?]?\s*$"#
        }
        return base + #"\s*[.!?]?\s*$"#
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
