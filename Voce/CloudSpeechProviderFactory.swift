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
            if dictation.cloud.transcriptionMode == .realtimeWhisper {
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
                    refinementModel: environmentValue("VOCE_OPENAI_REFINEMENT_MODEL") ?? "gpt-4o-mini",
                    transcriptionHints: Array(transcriptionHints.prefix(200))
                )
            }

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
                transcriptionModel: environmentValue("VOCE_OPENAI_TRANSCRIPTION_MODEL") ?? "gpt-4o-mini-transcribe",
                refinementModel: environmentValue("VOCE_OPENAI_REFINEMENT_MODEL") ?? "gpt-4o-mini",
                transcriptionHints: Array(transcriptionHints.prefix(200))
            )
        }

        return VoceCloudProxySpeechProviderClient(
            session: session,
            subscriberEmailProvider: subscriberEmailProvider,
            sessionStore: sessionStore
        )
    }

    private static func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
