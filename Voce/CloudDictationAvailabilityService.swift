import Foundation
import VoceKit

struct CloudDictationAvailabilityStatus: Sendable, Equatable {
    var message: String
    var isError: Bool
}

struct CloudDictationAvailabilityService: Sendable {
    let credentialStore: CloudProviderCredentialStore
    
    init(credentialStore: CloudProviderCredentialStore = .shared) {
        self.credentialStore = credentialStore
    }

    func directCredentialStatus(for dictation: AppPreferences.Dictation) -> CloudDictationAvailabilityStatus {
        switch dictation.cloud.apiKeySource {
        case .keychain:
            if credentialStore.hasStoredOpenAIAPIKey() {
                return CloudDictationAvailabilityStatus(message: "Ready. OpenAI key stored in Keychain.", isError: false)
            }
            return CloudDictationAvailabilityStatus(message: "Missing OpenAI API key in Keychain.", isError: true)
        case .environment:
            let hasKey = (ProcessInfo.processInfo.environment[credentialStore.environmentVariableDisplayName()]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            return hasKey
                ? CloudDictationAvailabilityStatus(
                    message: "Ready. Using \(credentialStore.environmentVariableDisplayName()) from the environment.",
                    isError: false
                )
                : CloudDictationAvailabilityStatus(
                    message: "Missing \(credentialStore.environmentVariableDisplayName()) in the environment.",
                    isError: true
                )
        }
    }
}
