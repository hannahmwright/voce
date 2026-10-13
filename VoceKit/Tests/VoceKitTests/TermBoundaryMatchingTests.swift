import Foundation
import Testing
@testable import VoceKit

private let naturalProfile = StyleProfile(
    name: "Boundary Fixture",
    tone: .natural,
    structureMode: .natural,
    fillerPolicy: .balanced,
    commandPolicy: .transform
)

@Test("Lexicon service applies terms that start or end with symbols")
func lexiconServiceAppliesSymbolTerms() async {
    let service = PersonalLexiconService()
    await service.upsert(term: "c#", preferred: "C#", scope: .global)
    await service.upsert(term: ".net", preferred: ".NET", scope: .global)

    let corrected = await service.apply(to: "I write c# on .net every day.", appContext: nil)

    #expect(corrected == "I write C# on .NET every day.")
}

@Test("Lexicon service symbol terms do not match inside larger words")
func lexiconServiceSymbolTermsRespectWordEdges() async {
    let service = PersonalLexiconService()
    await service.upsert(term: ".net", preferred: ".NET", scope: .global)
    await service.upsert(term: "cat", preferred: "CAT", scope: .global)

    let corrected = await service.apply(to: "asp.net and .network and concatenate, but cat.", appContext: nil)

    #expect(corrected == "asp.net and .network and concatenate, but CAT.")
}

@Test("Cleanup engine lexicon applies terms that start or end with symbols")
func cleanupEngineAppliesSymbolLexiconTerms() async throws {
    let lexicon = PersonalLexicon(entries: [
        LexiconEntry(term: "c#", preferred: "C#", scope: .global),
        LexiconEntry(term: ".net", preferred: ".NET", scope: .global),
    ])
    let engine = RuleBasedCleanupEngine()

    let candidate = engine.buildCandidate(
        raw: RawTranscript(text: "We moved the c# service to .net last year."),
        profile: naturalProfile,
        lexicon: lexicon,
        rulePathID: "test"
    )

    #expect(candidate.text == "We moved the C# service to .NET last year.")
}

@Test("Cleanup engine lexicon still applies ordinary word terms")
func cleanupEngineAppliesOrdinaryLexiconTerms() {
    let lexicon = PersonalLexicon(entries: [
        LexiconEntry(term: "voceh", preferred: "Voce", scope: .global),
    ])
    let engine = RuleBasedCleanupEngine()

    let candidate = engine.buildCandidate(
        raw: RawTranscript(text: "Open voceh, not vocehs."),
        profile: naturalProfile,
        lexicon: lexicon,
        rulePathID: "test"
    )

    #expect(candidate.text == "Open Voce, not vocehs.")
}

@Test("Snippets with symbol triggers expand")
func snippetSymbolTriggerExpands() async {
    let service = SnippetService(snippets: [
        Snippet(trigger: "@@sig", expansion: "Best, Hannah"),
    ])

    let expanded = await service.apply(to: "Thanks again @@sig", appContext: nil)
    let untouched = await service.apply(to: "Thanks again foo@@sigbar", appContext: nil)

    #expect(expanded == "Thanks again Best, Hannah")
    #expect(untouched == "Thanks again foo@@sigbar")
}
