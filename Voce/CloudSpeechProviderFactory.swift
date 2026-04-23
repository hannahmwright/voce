import Foundation
import VoceKit

enum CloudSpeechProviderFactory {
    static func makeProvider(
        dictation: AppPreferences.Dictation,
        transcriptionHints: [LexiconEntry],
        subscriberEmailProvider: @escaping @Sendable () -> String?,
        useDirectCredentials: Bool,
        credentialStore: CloudProviderCredentialStore = .shared,
        sessionStore: VoceAccessSessionStore = .shared,
        session: URLSession = .shared
    ) -> any CloudSpeechProviderClient {
        if useDirectCredentials {
            return OpenAICloudSpeechProviderClient(
                session: session,
                apiKeyProvider: {
                    do {
                        return try credentialStore.resolveOpenAIAPIKey(
                            source: dictation.cloud.apiKeySource
                        )
                    } catch CloudProviderCredentialStoreError.missingAPIKey {
                        throw CloudDictationError.missingAPIKey
                    } catch {
                        throw error
                    }
                },
                transcriptionHints: Array(transcriptionHints.prefix(200))
            )
        }

        return VoceCloudProxySpeechProviderClient(
            session: session,
            subscriberEmailProvider: subscriberEmailProvider,
            sessionStore: sessionStore
        )
    }
}
