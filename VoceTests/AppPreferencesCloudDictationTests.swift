import Foundation
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
    #expect(!preferences.dictation.cloud.openAIKeyFallbackEnabled)
    #expect(preferences.dictation.cloud.directUsagePeriodKey.isEmpty)
    #expect(preferences.dictation.cloud.directUsageSeconds == 0)
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

@Test("Voce Pro entitlement decodes hosted cloud usage fields")
func voceProEntitlementDecodesCloudUsageFields() throws {
    let payload = Data("""
    {
      "entitled": true,
      "source": "stripe",
      "feature": "voce_app_access",
      "email": "user@example.com",
      "planTier": "pro",
      "grantedFeatures": ["voce_app_access", "voce_cloud_dictation"],
      "expiresAt": null,
      "freeLimitSeconds": null,
      "freeUsedSeconds": null,
      "freeRemainingSeconds": null,
      "periodStartsAt": null,
      "periodEndsAt": null,
      "cloudLimitSeconds": 18000,
      "cloudUsedSeconds": 120,
      "cloudRemainingSeconds": 17880,
      "cloudPeriodStartsAt": 1767225600000,
      "cloudPeriodEndsAt": 1769904000000
    }
    """.utf8)

    let entitlement = try JSONDecoder().decode(VoceProEntitlement.self, from: payload)

    #expect(entitlement.cloudLimitSeconds == 18_000)
    #expect(entitlement.cloudUsedSeconds == 120)
    #expect(entitlement.cloudRemainingSeconds == 17_880)
    #expect(entitlement.cloudRemainingMinutesText == "298 minutes")
}
