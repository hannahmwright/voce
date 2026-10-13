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

// MARK: - Automatic list formatting

@Test(
    "Prose with ordinal or list words is not turned into a list",
    arguments: [
        "First we need to wait a second and then go.",
        "First of all thanks, second of all sorry.",
        "Bullet points are great, but slides are better.",
        "The bullet list was too long, so I cut it.",
        "Bullet list was too long, so I cut it.",
        "First I finished the draft and the second one is next.",
        "Numbered items are easier to scan, honestly.",
    ]
)
func proseIsNotAutoFormattedAsList(sentence: String) async throws {
    for structureMode in [StructureMode.natural, .paragraph] {
        let cleaned = try await cleanup(sentence, structureMode: structureMode)
        #expect(cleaned.text.contains("\n") == false)
        #expect(cleaned.edits.contains { $0.kind == .structureRewrite && $0.to.hasPrefix("auto-") } == false)
    }
}

@Test("Intended spoken lists are still formatted")
func intendedListsStillFormat() async throws {
    let ordinal = try await cleanup("first fix onboarding second test permissions third ship update")
    let twoItems = try await cleanup("first buy milk second call mom")
    let bullets = try await cleanup("bullet points: fix onboarding, test permissions, ship update")
    let bulletList = try await cleanup("bullet list fix onboarding, test permissions, ship update")
    let numbered = try await cleanup("numbered list: draft, review, publish")

    #expect(ordinal.text == "1. Fix onboarding\n2. Test permissions\n3. Ship update")
    #expect(twoItems.text == "1. Buy milk\n2. Call mom")
    #expect(bullets.text == "- Fix onboarding\n- Test permissions\n- Ship update")
    #expect(bulletList.text == "- Fix onboarding\n- Test permissions\n- Ship update")
    #expect(numbered.text == "1. Draft\n2. Review\n3. Publish")
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
