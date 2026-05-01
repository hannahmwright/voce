import Foundation
import VoceKit

struct CloudCleanupEngineAdapter: CleanupEngine, Sendable {
    private let refinementEngine: any TranscriptRefinementEngine
    private let currentAppContextProvider: @Sendable () -> AppContext?

    init(
        refinementEngine: any TranscriptRefinementEngine,
        currentAppContextProvider: @escaping @Sendable () -> AppContext? = { nil }
    ) {
        self.refinementEngine = refinementEngine
        self.currentAppContextProvider = currentAppContextProvider
    }

    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        let rawText = normalizeText(raw.text)
        guard !rawText.isEmpty else {
            return CleanTranscript(text: "")
        }

        var cleaned = try await refinementEngine.refine(
            raw: RawTranscript(
                text: rawText,
                segments: raw.segments,
                avgConfidence: raw.avgConfidence,
                durationMS: raw.durationMS
            ),
            profile: profile,
            lexicon: lexicon,
            appContext: currentAppContextProvider()
        )

        let lexiconService = PersonalLexiconService(entries: lexicon.entries)
        let lexiconResult = await lexiconService.applyWithEdits(to: cleaned.text, appContext: nil)
        cleaned.text = normalizeText(lexiconResult.text)
        cleaned.edits.append(contentsOf: lexiconResult.edits)

        if cleaned.text.isEmpty && !rawText.isEmpty {
            throw CloudDictationError.invalidResponse
        }

        return cleaned
    }

    private func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NoOpTranscriptRefinementEngine: TranscriptRefinementEngine, Sendable {
    func refine(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext?
    ) async throws -> CleanTranscript {
        _ = profile
        _ = lexicon
        _ = appContext
        return CleanTranscript(text: raw.text)
    }
}

struct FailingCleanupEngine: CleanupEngine, Sendable {
    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        _ = raw
        _ = profile
        _ = lexicon
        throw CloudDictationError.providerError("No fallback cleanup available.")
    }
}
