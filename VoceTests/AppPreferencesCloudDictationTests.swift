import Testing
import VoceKit
@testable import Voce

@Test("Cloud dictation defaults remain local-first")
func appPreferencesCloudDictationDefaults() {
    let preferences = AppPreferences.default

    #expect(preferences.dictation.engineMode == .local)
    #expect(preferences.dictation.cloud.provider == .openAI)
    #expect(preferences.dictation.cloud.refinementEnabled)
    #expect(preferences.dictation.cloud.apiKeySource == .keychain)
    #expect(preferences.appDictationEnginePreferences.isEmpty)
}

@Test("Changing cloud dictation runtime settings requires a runtime rebuild")
func appPreferencesCloudDictationRebuildSensitivity() {
    let baseline = AppPreferences.default
    var changed = baseline
    changed.appDictationEnginePreferences["com.apple.dt.Xcode"] = .cloud

    #expect(changed.requiresRuntimeRebuild(comparedTo: baseline))
}

@Test("Normalization removes follow-global app overrides")
func appPreferencesCloudDictationNormalizationRemovesFollowGlobalOverrides() {
    var preferences = AppPreferences.default
    preferences.appDictationEnginePreferences["com.apple.Notes"] = .followGlobal
    preferences.normalize()

    #expect(preferences.appDictationEnginePreferences.isEmpty)
}

@Test("Dictation engine resolver prefers app override over global mode")
func dictationEngineModeResolverUsesAppOverride() {
    let resolver = DictationEngineModeResolver(
        globalMode: .cloud,
        appPreferences: ["com.apple.Notes": .local],
        cloudModeAvailable: true
    )

    let resolved = resolver.resolve(for: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    #expect(resolved == .local)
}

@Test("Dictation engine resolver falls back to local when cloud is unavailable")
func dictationEngineModeResolverClampsUnavailableCloud() {
    let resolver = DictationEngineModeResolver(
        globalMode: .local,
        appPreferences: ["com.apple.dt.Xcode": .cloud],
        cloudModeAvailable: false
    )

    let resolved = resolver.resolve(for: AppContext(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
    #expect(resolved == .local)
}
