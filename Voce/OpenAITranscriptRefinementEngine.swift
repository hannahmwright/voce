import Foundation
import VoceKit

struct OpenAITranscriptRefinementEngine: TranscriptRefinementEngine, Sendable {
    private let provider: any CloudSpeechProviderClient
    private let localeIdentifier: String

    init(
        provider: any CloudSpeechProviderClient,
        localeIdentifier: String
    ) {
        self.provider = provider
        self.localeIdentifier = localeIdentifier
    }

    func refine(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext?
    ) async throws -> CleanTranscript {
        let refined = try await provider.refine(
            transcript: raw.text,
            localeIdentifier: localeIdentifier,
            dictionary: lexicon.entries,
            profile: profile,
            appContext: appContext
        )

        var edits: [TranscriptEdit] = []
        if raw.text != refined {
            edits.append(
                TranscriptEdit(
                    kind: .structureRewrite,
                    from: raw.text,
                    to: refined
                )
            )
        }

        return CleanTranscript(text: refined, edits: edits, removedFillers: [], uncertaintyFlags: [])
    }
}
