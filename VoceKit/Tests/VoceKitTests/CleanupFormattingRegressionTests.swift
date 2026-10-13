import Foundation
import Testing
@testable import VoceKit

private func profile(
    fillerPolicy: FillerPolicy = .balanced,
    structureMode: StructureMode = .natural
) -> StyleProfile {
    StyleProfile(
        name: "Regression Fixture",
        tone: .natural,
        structureMode: structureMode,
        fillerPolicy: fillerPolicy,
        commandPolicy: .transform
    )
}

private func cleanup(
    _ text: String,
    fillerPolicy: FillerPolicy = .balanced,
    structureMode: StructureMode = .natural,
    lexicon: PersonalLexicon = PersonalLexicon()
) async throws -> CleanTranscript {
    try await RuleBasedCleanupEngine().cleanup(
        raw: RawTranscript(text: text),
        profile: profile(fillerPolicy: fillerPolicy, structureMode: structureMode),
        lexicon: lexicon
    )
}

// MARK: - Filler removal punctuation

@Test(
    "Filler removal does not leave stray commas",
    arguments: [
        ("So, um, I think we should go.", "So, I think we should go."),
        ("First, uh, the um budget", "First, the budget"),
        ("Um, I think so.", "I think so."),
        ("Yes. Um, okay.", "Yes. okay."),
        ("I agree, uh.", "I agree."),
    ]
)
func fillerRemovalLeavesNoStrayCommas(input: String, expected: String) async throws {
    let cleaned = try await cleanup(input)

    #expect(cleaned.text == expected)
    #expect(cleaned.text.contains(", ,") == false)
}

@Test("Filler removal punctuation repair keeps symbol terms and ordinary commas")
func fillerRemovalKeepsSymbolTerms() async throws {
    let cleaned = try await cleanup("Um we use the .net stack, and it works :)")

    #expect(cleaned.text == "we use the .net stack, and it works :)")
}

@Test("Ranker fluency penalizes doubled commas")
func rankerPenalizesDoubledCommas() {
    let ranker = LocalCleanupRanker()
    let raw = "So, I think we should go."
    let clean = CleanupCandidate(text: raw, appliedEdits: [], removedFillers: [], rulePathID: "clean")
    let debris = CleanupCandidate(text: "So, , I think we should go.", appliedEdits: [], removedFillers: [], rulePathID: "debris")

    let cleanScore = ranker.scoreCandidate(rawText: raw, candidate: clean, profile: profile())
    let debrisScore = ranker.scoreCandidate(rawText: raw, candidate: debris, profile: profile())

    #expect(debrisScore.fluencyScore < cleanScore.fluencyScore)
}
