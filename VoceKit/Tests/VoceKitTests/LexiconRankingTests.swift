import Foundation
import Testing
@testable import VoceKit

private let lexicon = PersonalLexicon(entries: [
    LexiconEntry(term: "open ai", preferred: "OpenAI", scope: .global),
    LexiconEntry(term: "chat g p t", preferred: "ChatGPT", scope: .global),
    LexiconEntry(term: "teh", preferred: "the", scope: .global),
    LexiconEntry(term: "Kubernetties", preferred: "Kubernetes", scope: .global),
])

private func cleanup(_ text: String, structureMode: StructureMode = .natural) async throws -> CleanTranscript {
    let profile = StyleProfile(
        name: "Lexicon Fixture",
        tone: .natural,
        structureMode: structureMode,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
    return try await RuleBasedCleanupEngine().cleanup(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: lexicon
    )
}

@Test(
    "Lexicon corrections always survive ranking on short utterances",
    arguments: [
        ("I use open ai every day for work.", "I use OpenAI every day for work."),
        ("ask chat g p t about it", "ask ChatGPT about it"),
        ("teh cat", "the cat"),
        ("Kubernetties", "Kubernetes"),
    ]
)
func lexiconCorrectionsSurviveRanking(input: String, expected: String) async throws {
    let cleaned = try await cleanup(input)

    #expect(cleaned.text == expected)
    #expect(cleaned.edits.contains { $0.kind == .lexiconCorrection })
}

@Test("Lexicon corrections combine with filler removal")
func lexiconCorrectionsCombineWithFillerRemoval() async throws {
    let cleaned = try await cleanup("Um I deployed it to Kubernetties uh yesterday.")

    #expect(cleaned.text == "I deployed it to Kubernetes yesterday.")
}

@Test("Text without lexicon terms is unaffected by a non-empty lexicon")
func lexiconDoesNotTouchUnrelatedText() async throws {
    let cleaned = try await cleanup("The open door policy works for the team.")

    #expect(cleaned.text == "The open door policy works for the team.")
    #expect(cleaned.edits.contains { $0.kind == .lexiconCorrection } == false)
}

@Test("Candidate generator applies lexicon to the pass-through candidate")
func generatorAppliesLexiconToPassThrough() async throws {
    let profile = StyleProfile(
        name: "Generator",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    let candidates = try await RuleBasedCleanupCandidateGenerator().generateCandidates(
        raw: RawTranscript(text: "teh cat sat"),
        profile: profile,
        lexicon: lexicon
    )

    #expect(candidates.allSatisfy { $0.text.contains("teh") == false })
    #expect(candidates.first?.rulePathID == "raw-pass-through")
}

@Test("Ranker tokenization keeps accented words and contractions intact")
func rankerTokenizationIsUnicodeAware() {
    let profile = StyleProfile(
        name: "Ranker",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
    let ranker = LocalCleanupRanker(wordFrequencies: ["café": 50, "don't": 50])
    let raw = "Café, don't."
    let candidate = CleanupCandidate(text: raw, appliedEdits: [], removedFillers: [], rulePathID: "raw")

    let score = ranker.scoreCandidate(rawText: raw, candidate: candidate, profile: profile)

    #expect(score.editDistancePenalty == 0)
    #expect(WordTokenizer.words(in: "Café don’t 'quoted' naïve-test") == ["café", "don't", "quoted", "naïve", "test"])
}
