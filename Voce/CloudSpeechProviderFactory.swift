import Foundation
import VoceKit

enum CloudSpeechProviderFactory {
    static func makeProvider(
        dictation: AppPreferences.Dictation,
        useDirectCredentials: Bool,
        credentialStore: CloudProviderCredentialStore = .shared,
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

        return UnavailableCloudSpeechProviderClient(
            message: "Realtime Whisper requires direct OpenAI credentials in this build."
        )
    }

    private static func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct UnavailableCloudSpeechProviderClient: CloudSpeechProviderClient {
    let message: String

    func preflightCheck(localeIdentifier: String) async throws {
        throw CloudDictationError.providerError(message)
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        throw CloudDictationError.providerError(message)
    }

    func refine(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) async throws -> String {
        throw CloudDictationError.providerError(message)
    }
}
