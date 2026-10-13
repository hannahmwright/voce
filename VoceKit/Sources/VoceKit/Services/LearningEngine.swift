import Foundation

/// Adaptive learning engine that improves transcription accuracy over time.
///
/// After each dictation session, the engine:
/// 1. Updates word frequency counts (for candidate ranking bias)
/// 2. Extracts repeated n-gram phrases (for snippet auto-suggestions)
/// 3. Records per-app usage patterns (for style profile suggestions)
///
/// Corrections are recorded separately via `recordCorrection()` and
/// auto-promoted to lexicon entries after reaching the promotion threshold.
public actor LearningEngine {
    private var data: LearningData
    private let storageURL: URL
    private var isDirty = false
    /// Set when an unreadable data file could not be preserved; saving would
    /// then destroy it, so saves are skipped.
    private let isPersistenceBlocked: Bool

    /// Number of times a correction must be seen before auto-promoting to lexicon.
    public static let correctionPromotionThreshold = 3

    /// Minimum occurrences of a phrase before suggesting it as a snippet.
    public static let snippetSuggestionThreshold = 5

    /// Minimum sessions per app before suggesting a style profile.
    public static let styleSuggestionMinSessions = 10

    /// N-gram sizes to track for snippet suggestions (3-word to 8-word phrases).
    private static let ngramRange = 3...8
    private static let snippetStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "if",
        "in", "into", "is", "it", "its", "me", "my", "of", "on", "or", "that", "the",
        "their", "them", "there", "this", "to", "up", "us", "we", "with", "you", "your"
    ]
    private static let rejectedSnippetPhrases: Set<String> = [
        "to be able to",
        "i want to be",
        "i want to be able",
        "i need to be",
        "i need to be able"
    ]

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        let loaded = Self.load(from: self.storageURL)
        self.data = loaded.data
        self.isPersistenceBlocked = loaded.persistenceBlocked
    }

    // MARK: - Session Observation

    /// Call after each successful dictation to update learning data.
    public func observeSession(
        rawText: String,
        cleanText: String,
        removedFillers: [String],
        appBundleID: String
    ) {
        updateWordFrequencies(from: cleanText)
        updatePhraseFrequencies(from: cleanText)
        updateAppStats(
            bundleID: appBundleID,
            rawText: rawText,
            cleanText: cleanText,
            removedFillers: removedFillers
        )
        isDirty = true
    }

    /// Persist data to disk. Call periodically or on app termination.
    public func save() {
        guard isDirty, !isPersistenceBlocked else { return }
        Self.persist(data, to: storageURL)
        isDirty = false
    }

    // MARK: - Corrections

    /// Record a user correction (raw word was wrong, should have been correctedWord).
    /// Returns a LexiconEntry if the correction has been seen enough times to auto-promote.
    @discardableResult
    public func recordCorrection(rawWord: String, correctedWord: String) -> LexiconEntry? {
        let normalizedRaw = rawWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = correctedWord.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedRaw.isEmpty, !trimmedCorrected.isEmpty else { return nil }

        if let idx = data.corrections.firstIndex(where: {
            $0.rawWord.lowercased() == normalizedRaw
            && $0.correctedWord.lowercased() == trimmedCorrected.lowercased()
        }) {
            data.corrections[idx].count += 1
            data.corrections[idx].lastSeen = Date()
            isDirty = true

            if data.corrections[idx].count >= Self.correctionPromotionThreshold
                && !data.corrections[idx].promoted {
                data.corrections[idx].promoted = true
                return LexiconEntry(
                    term: data.corrections[idx].rawWord,
                    preferred: data.corrections[idx].correctedWord,
                    scope: .global
                )
            }
        } else {
            let correction = Correction(
                rawWord: normalizedRaw,
                correctedWord: trimmedCorrected
            )
            data.corrections.append(correction)
            isDirty = true

            if Self.correctionPromotionThreshold <= 1 {
                return LexiconEntry(term: normalizedRaw, preferred: trimmedCorrected, scope: .global)
            }
        }

        return nil
    }

    /// Returns all corrections, sorted by count descending.
    public func corrections() -> [Correction] {
        data.corrections.sorted { $0.count > $1.count }
    }

    // MARK: - Word Frequencies

    /// Returns the frequency count for a given word.
    public func frequency(of word: String) -> Int {
        data.wordFrequencies[WordTokenizer.normalizedText(word)] ?? 0
    }

    /// Returns a snapshot of word frequencies for use in candidate ranking.
    public func wordFrequencySnapshot() -> [String: Int] {
        data.wordFrequencies
    }

    // MARK: - Snippet Suggestions

    /// Returns phrases that have been repeated enough to suggest as snippets.
    public func snippetSuggestions(excluding existingTriggers: Set<String> = []) -> [SnippetSuggestion] {
        let lowercasedTriggers = Set(existingTriggers.map { $0.lowercased() })
        let candidates = data.phraseFrequencies
            .filter { $0.value >= Self.snippetSuggestionThreshold }
            .compactMap { (entry: Dictionary<String, Int>.Element) -> SnippetSuggestion? in
                let (phrase, occurrences) = entry
                let normalizedPhrase = phrase.lowercased()
                guard !data.dismissedSnippetPhrases.contains(normalizedPhrase) else { return nil }
                guard shouldSuggestSnippetPhrase(normalizedPhrase) else { return nil }
                guard let suggestedTrigger = makeSuggestedTrigger(for: normalizedPhrase) else { return nil }
                guard !lowercasedTriggers.contains(normalizedPhrase) else { return nil }
                guard !lowercasedTriggers.contains(suggestedTrigger.lowercased()) else { return nil }
                return SnippetSuggestion(
                    phrase: normalizedPhrase,
                    suggestedTrigger: suggestedTrigger,
                    occurrences: occurrences
                )
            }
            .sorted { (lhs: SnippetSuggestion, rhs: SnippetSuggestion) in
                if lhs.occurrences != rhs.occurrences {
                    return lhs.occurrences > rhs.occurrences
                }
                return wordCount(in: lhs.phrase) > wordCount(in: rhs.phrase)
            }

        var filtered: [SnippetSuggestion] = []
        for candidate in candidates {
            let isOverlappingFragment = filtered.contains { existing in
                existing.occurrences >= candidate.occurrences
                    && containsPhrase(existing.phrase, candidate.phrase)
            }
            if !isOverlappingFragment {
                filtered.append(candidate)
            }
        }

        return filtered
    }

    /// Dismiss a snippet suggestion so it won't be suggested again.
    ///
    /// The phrase is remembered (and persisted) so that dictating it again does
    /// not rebuild its count and bring the suggestion back.
    public func dismissSnippetSuggestion(phrase: String) {
        let normalized = phrase.lowercased()
        data.dismissedSnippetPhrases.insert(normalized)
        data.phraseFrequencies.removeValue(forKey: normalized)
        isDirty = true
    }

    // MARK: - Style Suggestions

    /// Returns per-app style suggestions based on observed usage patterns.
    public func styleSuggestions(currentProfiles: [String: StyleProfile]) -> [StyleSuggestion] {
        var suggestions: [StyleSuggestion] = []

        for (bundleID, stats) in data.appStats {
            guard stats.sessionCount >= Self.styleSuggestionMinSessions else { continue }
            guard currentProfiles[bundleID] == nil else { continue }

            if let suggestion = suggestProfile(for: bundleID, stats: stats) {
                suggestions.append(suggestion)
            }
        }

        return suggestions.sorted { $0.confidence > $1.confidence }
    }

    /// Returns raw app stats for a given bundle ID.
    public func appStats(for bundleID: String) -> AppUsageStats? {
        data.appStats[bundleID]
    }

    // MARK: - Private: Word Frequencies

    private func updateWordFrequencies(from text: String) {
        let words = tokenize(text)
        for word in words {
            data.wordFrequencies[word, default: 0] += 1
        }

        if data.wordFrequencies.count > Self.maxWordFrequencyEntries {
            data.wordFrequencies = Self.pruned(
                data.wordFrequencies,
                keepingCount: Self.wordFrequencyEntriesAfterPruning,
                preserving: Set(words)
            )
        }
    }

    // MARK: - Private: Phrase Frequencies

    private func updatePhraseFrequencies(from text: String) {
        let words = tokenize(text)
        guard words.count >= Self.ngramRange.lowerBound else { return }

        var sessionPhrases: Set<String> = []
        for n in Self.ngramRange {
            guard words.count >= n else { break }
            for i in 0...(words.count - n) {
                let phrase = words[i..<(i + n)].joined(separator: " ")
                guard !data.dismissedSnippetPhrases.contains(phrase) else { continue }
                data.phraseFrequencies[phrase, default: 0] += 1
                sessionPhrases.insert(phrase)
            }
        }

        // Bound growth: once over the limit, keep this session's phrases plus
        // the most frequent others, dropping well below the limit so pruning
        // runs rarely rather than rescanning on every session.
        if data.phraseFrequencies.count > Self.maxPhraseFrequencyEntries {
            data.phraseFrequencies = Self.pruned(
                data.phraseFrequencies,
                keepingCount: Self.phraseFrequencyEntriesAfterPruning,
                preserving: sessionPhrases
            )
        }
    }

    static let maxPhraseFrequencyEntries = 10_000
    static let phraseFrequencyEntriesAfterPruning = 5_000
    static let maxWordFrequencyEntries = 20_000
    static let wordFrequencyEntriesAfterPruning = 15_000

    /// Keeps every key in `preserving` (the current session — the most recent
    /// data) plus the highest counts, up to `keepingCount` entries in total.
    static func pruned(
        _ counts: [String: Int],
        keepingCount: Int,
        preserving: Set<String>
    ) -> [String: Int] {
        var kept: [String: Int] = [:]
        kept.reserveCapacity(keepingCount)
        for key in preserving {
            if let count = counts[key] {
                kept[key] = count
            }
        }

        let remainingBudget = keepingCount - kept.count
        guard remainingBudget > 0 else { return kept }

        let others = counts
            .filter { !preserving.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(remainingBudget)
        for (key, count) in others {
            kept[key] = count
        }
        return kept
    }

    // MARK: - Private: App Stats

    private func updateAppStats(
        bundleID: String,
        rawText: String,
        cleanText: String,
        removedFillers: [String]
    ) {
        guard !bundleID.isEmpty else { return }

        var stats = data.appStats[bundleID] ?? AppUsageStats()
        let wordCount = tokenize(cleanText).count
        let rawWordCount = tokenize(rawText).count
        let n = Double(stats.sessionCount)

        stats.sessionCount += 1
        stats.totalWordCount += wordCount

        // Running average of filler rate
        let sessionFillerRate = rawWordCount > 0
            ? Double(removedFillers.count) / Double(rawWordCount)
            : 0
        stats.fillerRate = (stats.fillerRate * n + sessionFillerRate) / (n + 1)

        // Running average of transcript length
        stats.averageLength = (stats.averageLength * n + Double(wordCount)) / (n + 1)

        // Structure hints
        let isShort = wordCount < 5
        stats.structureHints.shortCommandRate =
            (stats.structureHints.shortCommandRate * n + (isShort ? 1 : 0)) / (n + 1)

        let hasFormalPunctuation = cleanText.hasSuffix(".") || cleanText.hasSuffix("!")
        stats.structureHints.punctuationRate =
            (stats.structureHints.punctuationRate * n + (hasFormalPunctuation ? 1 : 0)) / (n + 1)

        let formalWords: Set<String> = ["please", "kindly", "regards", "sincerely", "thank", "appreciate"]
        let words = Set(tokenize(cleanText))
        let formalHits = Double(words.intersection(formalWords).count)
        let formalitySignal = min(formalHits / 2.0, 1.0)
        stats.structureHints.formalityScore =
            (stats.structureHints.formalityScore * n + formalitySignal) / (n + 1)

        data.appStats[bundleID] = stats
    }

    // MARK: - Private: Style Suggestion Logic

    private func suggestProfile(for bundleID: String, stats: AppUsageStats) -> StyleSuggestion? {
        let hints = stats.structureHints

        // Short commands + low formality → command mode
        if hints.shortCommandRate > 0.6 && stats.averageLength < 8 {
            return StyleSuggestion(
                bundleID: bundleID,
                suggestedProfile: StyleProfile(
                    name: "Auto: Command",
                    tone: .concise,
                    structureMode: .command,
                    fillerPolicy: .aggressive,
                    commandPolicy: .passthrough
                ),
                reason: "You mostly dictate short commands in this app (\(Int(hints.shortCommandRate * 100))% under 5 words)",
                confidence: hints.shortCommandRate
            )
        }

        // High formality + punctuation → professional paragraph
        if hints.formalityScore > 0.3 && hints.punctuationRate > 0.5 {
            return StyleSuggestion(
                bundleID: bundleID,
                suggestedProfile: StyleProfile(
                    name: "Auto: Professional",
                    tone: .professional,
                    structureMode: .paragraph,
                    fillerPolicy: .aggressive,
                    commandPolicy: .transform
                ),
                reason: "Your dictation in this app tends to be formal with proper punctuation",
                confidence: (hints.formalityScore + hints.punctuationRate) / 2
            )
        }

        // High filler rate → suggest aggressive filler removal
        if stats.fillerRate > 0.15 {
            return StyleSuggestion(
                bundleID: bundleID,
                suggestedProfile: StyleProfile(
                    name: "Auto: Clean",
                    tone: .natural,
                    structureMode: .natural,
                    fillerPolicy: .aggressive,
                    commandPolicy: .transform
                ),
                reason: "You use a lot of filler words in this app (\(Int(stats.fillerRate * 100))% of words) — aggressive cleanup recommended",
                confidence: min(stats.fillerRate * 3, 0.9)
            )
        }

        return nil
    }

    // MARK: - Tokenization

    /// Uses the tokenizer shared with the cleanup ranker so `wordFrequencies`
    /// keys match what the ranker looks up ("don't" stays one word, accents kept).
    private func tokenize(_ text: String) -> [String] {
        WordTokenizer.words(in: text).filter { $0.count > 1 }
    }

    private func shouldSuggestSnippetPhrase(_ phrase: String) -> Bool {
        guard !Self.rejectedSnippetPhrases.contains(phrase) else { return false }

        let words = tokenize(phrase)
        guard words.count >= 4 else { return false }
        guard phrase.count >= 12 else { return false }

        let contentWords = words.filter { !Self.snippetStopWords.contains($0) }
        let contentRatio = Double(contentWords.count) / Double(words.count)

        guard contentWords.count >= 2 else { return false }
        guard contentRatio >= 0.4 else { return false }
        guard Set(words).count >= 3 else { return false }

        return true
    }

    private func makeSuggestedTrigger(for phrase: String) -> String? {
        let words = tokenize(phrase)
        guard words.count >= 4 else { return nil }

        let maximumPrefixLength = min(4, words.count - 2)
        if maximumPrefixLength >= 2 {
            for prefixLength in 2...maximumPrefixLength {
                let prefixWords = Array(words.prefix(prefixLength))
                guard let lastWord = prefixWords.last, !Self.snippetStopWords.contains(lastWord) else {
                    continue
                }
                let candidate = prefixWords.joined(separator: " ")
                if wordCount(in: phrase) - prefixLength >= 2 && candidate.count < phrase.count {
                    return candidate
                }
            }
        }

        let contentWords = words.filter { !Self.snippetStopWords.contains($0) }
        let fallbackWords = Array(contentWords.prefix(3))
        guard fallbackWords.count >= 2 else { return nil }

        let fallback = fallbackWords.joined(separator: " ")
        if fallback != phrase && fallback.count < phrase.count {
            return fallback
        }
        return nil
    }

    private func containsPhrase(_ fullPhrase: String, _ candidatePhrase: String) -> Bool {
        let paddedFullPhrase = " \(fullPhrase) "
        let paddedCandidatePhrase = " \(candidatePhrase) "
        return paddedFullPhrase.contains(paddedCandidatePhrase)
    }

    private func wordCount(in phrase: String) -> Int {
        tokenize(phrase).count
    }

    // MARK: - Persistence

    private static func defaultStorageURL() -> URL {
        VoceRuntimeConfiguration.applicationSupportDirectory(fileName: "learning-data.json")
    }

    private static func load(from url: URL) -> (data: LearningData, persistenceBlocked: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.empty, false)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let report = LossyDecodingReport()
            decoder.attach(report)
            let decoded = try decoder.decode(LearningData.self, from: data)
            if report.skippedValueCount > 0 {
                // Keep the original before the next save drops the bad parts.
                let preserved = CorruptFilePreserver.preserve(fileAt: url, moving: false) != nil
                return (decoded, !preserved)
            }
            return (decoded, false)
        } catch {
            // Move the unreadable file aside so the next save cannot destroy it.
            let preserved = CorruptFilePreserver.preserve(fileAt: url, moving: true) != nil
            return (.empty, !preserved && FileManager.default.fileExists(atPath: url.path))
        }
    }

    private static func persist(_ learningData: LearningData, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(learningData) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
