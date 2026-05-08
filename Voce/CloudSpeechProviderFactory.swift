import Foundation
import VoceKit

enum CloudSpeechProviderFactory {
    static func makeProvider(
        dictation: AppPreferences.Dictation,
        useDirectCredentials: Bool,
        subscriberEmail: String,
        credentialStore: CloudProviderCredentialStore = .shared,
        accessSessionStore: VoceAccessSessionStore = .shared,
        session: URLSession = .shared
    ) -> any CloudSpeechProviderClient {
        if useDirectCredentials {
            return OpenAIRealtimeWhisperSpeechProviderClient(
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
                transcriptionModel: environmentValue("VOCE_OPENAI_REALTIME_TRANSCRIPTION_MODEL") ?? "gpt-realtime-whisper",
                refinementModel: environmentValue("VOCE_OPENAI_REFINEMENT_MODEL") ?? "gpt-4o-mini"
            )
        }

        return VoceCloudSpeechProviderClient(
            subscriberEmail: subscriberEmail,
            sessionStore: accessSessionStore,
            session: session
        )
    }

    private static func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
