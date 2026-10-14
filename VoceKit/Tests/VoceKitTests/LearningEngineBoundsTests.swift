import Foundation
import Testing
@testable import VoceKit

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("voce-learning-bounds-\(UUID().uuidString).json")
}

private let repeatedPhrase = "please review the quarterly budget proposal"

private func observe(_ engine: LearningEngine, _ text: String, times: Int = 1) async {
    for _ in 0..<times {
        await engine.observeSession(rawText: text, cleanText: text, removedFillers: [], appBundleID: "com.test")
    }
}

@Test("Dismissed snippet suggestions stay dismissed after more dictation and a reload")
func dismissedSuggestionsStayDismissed() async throws {
    let url = tempURL()
    let engine = LearningEngine(storageURL: url)
    await observe(engine, repeatedPhrase, times: 6)

    let suggestion = try #require(await engine.snippetSuggestions().first { $0.phrase == repeatedPhrase })
    await engine.dismissSnippetSuggestion(phrase: suggestion.phrase)

    // Dictating the phrase again must not bring the suggestion back.
    await observe(engine, repeatedPhrase, times: 6)
    #expect(await engine.snippetSuggestions().contains { $0.phrase == repeatedPhrase } == false)

    await engine.save()
    let reloaded = LearningEngine(storageURL: url)
    await observe(reloaded, repeatedPhrase, times: 6)
    #expect(await reloaded.snippetSuggestions().contains { $0.phrase == repeatedPhrase } == false)
}

@Test("Undismissed phrases are still suggested")
func undismissedPhrasesStillSuggested() async {
    let engine = LearningEngine(storageURL: tempURL())
    await observe(engine, repeatedPhrase, times: 6)
    await observe(engine, "send the signed contract to legal", times: 6)

    await engine.dismissSnippetSuggestion(phrase: repeatedPhrase)

    let suggestions = await engine.snippetSuggestions()
    #expect(suggestions.contains { $0.phrase == "send the signed contract to legal" })
}

@Test("Learning data files without dismissed phrases still decode")
func learningDataDecodesWithoutDismissedPhrases() throws {
    let json = #"{"wordFrequencies":{"hello":2},"corrections":[],"phraseFrequencies":{},"appStats":{}}"#

    let data = try JSONDecoder().decode(LearningData.self, from: Data(json.utf8))

    #expect(data.wordFrequencies["hello"] == 2)
    #expect(data.dismissedSnippetPhrases.isEmpty)
}

@Test("Phrase pruning keeps the current session and the most frequent phrases")
func phrasePruningKeepsSessionAndTopCounts() {
    var counts: [String: Int] = [:]
    for index in 0..<12_000 {
        counts["phrase \(index)"] = index % 7 == 0 ? 9 : 1
    }
    counts["current session phrase"] = 1

    let pruned = LearningEngine.pruned(
        counts,
        keepingCount: LearningEngine.phraseFrequencyEntriesAfterPruning,
        preserving: ["current session phrase"]
    )

    #expect(pruned.count == LearningEngine.phraseFrequencyEntriesAfterPruning)
    #expect(pruned["current session phrase"] == 1)
    // All frequently seen phrases (count 9) fit within the budget and survive.
    let frequent = counts.filter { $0.value == 9 }.map(\.key)
    #expect(frequent.allSatisfy { pruned[$0] == 9 })
}

@Test("Phrase and word tables stay bounded across many unique sessions")
func learningTablesStayBounded() async {
    let engine = LearningEngine(storageURL: tempURL())

    // Each session introduces new unique words and phrases.
    for session in 0..<1_500 {
        let words = (0..<16).map { "w\(session)x\($0)" }.joined(separator: " ")
        await observe(engine, words)
    }

    let wordCount = await engine.wordFrequencySnapshot().count
    #expect(wordCount <= LearningEngine.maxWordFrequencyEntries)
    // The newest session's words are always kept.
    #expect(await engine.frequency(of: "w1499x0") == 1)
}

@Test("Learning engine tokenizer keeps contractions and accents")
func learningEngineTokenizerIsUnicodeAware() async {
    let engine = LearningEngine(storageURL: tempURL())
    await observe(engine, "Don’t forget the café")

    #expect(await engine.frequency(of: "don't") == 1)
    #expect(await engine.frequency(of: "café") == 1)
    #expect(await engine.frequency(of: "don") == 0)
}
