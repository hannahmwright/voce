import Testing
import VoceKit
@testable import Voce

@Test("Cloud refinement prompt keeps final intended correction examples explicit")
func cloudRefinementPromptIncludesFinalIntentCorrectionRules() {
    let profile = StyleProfile(
        name: "Default",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    let prompt = OpenAICloudSpeechProviderClient.buildRefinementPrompt(
        transcript: "Yesterday I went to Publix or I meant Lowes to pick up groceries",
        localeIdentifier: "en-US",
        dictionary: [],
        profile: profile,
        appContext: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    )

    #expect(prompt.system.contains("\"or I meant\""))
    #expect(prompt.system.contains("\"no actually\""))
    #expect(prompt.system.contains("keep only the final intended version"))
    #expect(prompt.system.contains("Yesterday I went to Lowes to pick up groceries."))
    #expect(prompt.system.contains("Let's do abc."))
}
