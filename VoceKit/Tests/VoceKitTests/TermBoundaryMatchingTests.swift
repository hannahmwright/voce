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

// MARK: - Snippet ordering

@Test("Longer snippet trigger wins over a shorter trigger it contains")
func snippetLongestTriggerWins() async {
    let service = SnippetService(snippets: [
        Snippet(trigger: "my address", expansion: "1 Main St"),
        Snippet(trigger: "my address work", expansion: "500 Market St"),
    ])

    let expanded = await service.apply(to: "Send it to my address work please", appContext: nil)
    let shortStillWorks = await service.apply(to: "Send it to my address please", appContext: nil)

    #expect(expanded == "Send it to 500 Market St please")
    #expect(shortStillWorks == "Send it to 1 Main St please")
}

@Test("App-specific snippet wins over a global snippet with the same trigger")
func snippetAppSpecificWinsOverGlobal() async {
    let slack = AppContext(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack")
    let notes = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let service = SnippetService(snippets: [
        Snippet(trigger: "sig", expansion: "Global signature"),
        Snippet(trigger: "sig", expansion: "Slack signature", scope: .app(bundleID: slack.bundleIdentifier)),
    ])

    let inSlack = await service.apply(to: "thanks sig", appContext: slack)
    let inNotes = await service.apply(to: "thanks sig", appContext: notes)

    #expect(inSlack == "thanks Slack signature")
    #expect(inNotes == "thanks Global signature")
}

@Test("Snippet expansions are not re-expanded")
func snippetExpansionIsSinglePass() async {
    let service = SnippetService(snippets: [
        Snippet(trigger: "greet", expansion: "hello sig"),
        Snippet(trigger: "sig", expansion: "Hannah"),
    ])

    let expanded = await service.apply(to: "greet and sig", appContext: nil)

    #expect(expanded == "hello sig and Hannah")
}

@Test("Snippet expansion preserves multi-line text and template characters")
func snippetExpansionPreservesNewlinesAndTemplateCharacters() async {
    let service = SnippetService(snippets: [
        Snippet(trigger: "addr", expansion: "1 Main St\nSpringfield $1 \\0"),
    ])

    let expanded = await service.apply(to: "Ship to ADDR.", appContext: nil)

    #expect(expanded == "Ship to 1 Main St\nSpringfield $1 \\0.")
}
