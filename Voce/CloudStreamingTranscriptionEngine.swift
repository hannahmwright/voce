import Foundation
import VoceKit

struct CloudStreamingTranscriptionEngine: TranscriptionEngine, Sendable {
    private let provider: any CloudSpeechProviderClient
    private let localeIdentifier: String

    init(
        provider: any CloudSpeechProviderClient,
        localeIdentifier: String
    ) {
        self.provider = provider
        self.localeIdentifier = localeIdentifier
    }

    func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        try await provider.transcribe(
            audioURL: audioURL,
            localeIdentifier: localeIdentifier,
            hints: languageHints
        )
    }
}
