import Foundation
import OSLog
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

struct ChunkedTranscriptRefinementEngine: TranscriptRefinementEngine, Sendable {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "OpenAICloudSpeech")

    private let provider: any CloudSpeechProviderClient
    private let localeIdentifier: String
    private let thresholdWordCount: Int
    private let targetChunkWordCount: Int

    init(
        provider: any CloudSpeechProviderClient,
        localeIdentifier: String,
        thresholdWordCount: Int = 120,
        targetChunkWordCount: Int = 80
    ) {
        self.provider = provider
        self.localeIdentifier = localeIdentifier
        self.thresholdWordCount = max(2, thresholdWordCount)
        self.targetChunkWordCount = max(1, targetChunkWordCount)
    }

    func refine(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext?
    ) async throws -> CleanTranscript {
        let chunks = Self.makeChunks(
            from: raw.text,
            thresholdWordCount: thresholdWordCount,
            targetChunkWordCount: targetChunkWordCount
        )
        guard chunks.count > 1 else {
            let refined = try await provider.refine(
                transcript: raw.text,
                localeIdentifier: localeIdentifier,
                dictionary: lexicon.entries,
                profile: profile,
                appContext: appContext
            )
            return Self.cleanTranscript(rawText: raw.text, refinedText: refined)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        Self.logger.notice(
            "Starting chunked transcript refinement [chunks=\(chunks.count, privacy: .public), inputChars=\(raw.text.count, privacy: .public), targetWords=\(targetChunkWordCount, privacy: .public)]"
        )

        var refinedChunks = Array(repeating: "", count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let refined = try await provider.refine(
                        transcript: chunk,
                        localeIdentifier: localeIdentifier,
                        dictionary: lexicon.entries,
                        profile: profile,
                        appContext: appContext
                    )
                    return (index, refined)
                }
            }

            for try await (index, refined) in group {
                refinedChunks[index] = refined
            }
        }

        let refined = Self.normalizeText(refinedChunks.joined(separator: "\n\n"))
        Self.logger.notice(
            "Chunked transcript refinement completed in \(Self.seconds(from: startedAt.duration(to: clock.now)), format: .fixed(precision: 2))s [outputChars=\(refined.count, privacy: .public)]"
        )
        return Self.cleanTranscript(rawText: raw.text, refinedText: refined)
    }

    private static func cleanTranscript(rawText: String, refinedText: String) -> CleanTranscript {
        var edits: [TranscriptEdit] = []
        if rawText != refinedText {
            edits.append(
                TranscriptEdit(
                    kind: .structureRewrite,
                    from: rawText,
                    to: refinedText
                )
            )
        }

        return CleanTranscript(text: refinedText, edits: edits, removedFillers: [], uncertaintyFlags: [])
    }

    private static func makeChunks(
        from text: String,
        thresholdWordCount: Int,
        targetChunkWordCount: Int
    ) -> [String] {
        let words = Self.words(in: text)
        guard words.count >= thresholdWordCount else {
            return [text]
        }

        var chunks: [String] = []
        var currentParts: [String] = []
        var currentWordCount = 0

        for sentence in sentenceUnits(from: text) {
            let sentenceWordCount = Self.words(in: sentence).count
            guard sentenceWordCount > 0 else { continue }

            if sentenceWordCount > targetChunkWordCount {
                if !currentParts.isEmpty {
                    chunks.append(currentParts.joined(separator: " "))
                    currentParts = []
                    currentWordCount = 0
                }
                chunks.append(contentsOf: wordChunks(from: sentence, targetChunkWordCount: targetChunkWordCount))
                continue
            }

            if currentWordCount > 0,
               currentWordCount + sentenceWordCount > targetChunkWordCount {
                chunks.append(currentParts.joined(separator: " "))
                currentParts = []
                currentWordCount = 0
            }

            currentParts.append(sentence)
            currentWordCount += sentenceWordCount
        }

        if !currentParts.isEmpty {
            chunks.append(currentParts.joined(separator: " "))
        }

        return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func sentenceUnits(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var units: [String] = []
        var start = normalized.startIndex
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let character = normalized[index]
            if ".!?;".contains(character) || character == "\n" {
                let next = normalized.index(after: index)
                let unit = normalized[start ..< next]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty {
                    units.append(String(unit))
                }
                start = next
            }
            index = normalized.index(after: index)
        }

        let tail = normalized[start ..< normalized.endIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            units.append(String(tail))
        }

        return units.isEmpty ? [normalized] : units
    }

    private static func wordChunks(from text: String, targetChunkWordCount: Int) -> [String] {
        let words = Self.words(in: text)
        guard words.count > targetChunkWordCount else { return [text] }

        var chunks: [String] = []
        var index = 0
        while index < words.count {
            let end = min(index + targetChunkWordCount, words.count)
            chunks.append(words[index ..< end].joined(separator: " "))
            index = end
        }
        return chunks
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
