@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech
import VoceKit

enum AppleSpeechTranscriptionError: Error, LocalizedError {
    case localeUnavailable(String)
    case failedToReadAudio(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .localeUnavailable(let localeIdentifier):
            return "Apple Speech doesn't support the locale \(localeIdentifier)."
        case .failedToReadAudio(let details):
            return "Failed to read audio for Apple Speech transcription: \(details)"
        case .emptyTranscript:
            return "No speech was captured from the microphone"
        }
    }
}

struct AppleSpeechTranscriptionEngine: TranscriptionEngine, Sendable {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "AppleSpeechTranscription")

    struct Configuration: Sendable {
        var localeIdentifier: String
    }

    private let config: Configuration

    init(config: Configuration) {
        self.config = config
    }

    func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        let preferredLocaleIdentifier = languageHints.first ?? config.localeIdentifier

        return try await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let startedAt = clock.now
            let locale = try await Self.resolveLocale(identifier: preferredLocaleIdentifier)
            let audioFile = try Self.openAudioFile(at: audioURL)
            var preset = DictationTranscriber.Preset.longDictation
            preset.transcriptionOptions.formUnion([.emoji, .etiquetteReplacements])
            // We only use the final text. Asking Apple for alternatives,
            // frequent incremental finalizations, and confidence data adds
            // work without improving the inserted result.
            preset.attributeOptions.formUnion([.audioTimeRange])

            let transcriber = DictationTranscriber(locale: locale, preset: preset)
            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: .init(priority: .userInitiated, modelRetention: .whileInUse)
            )

            let resultsTask = Task(priority: .userInitiated) {
                var collected: [DictationTranscriber.Result] = []
                for try await result in transcriber.results {
                    collected.append(result)
                }
                return collected
            }

            do {
                try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                let results = try await resultsTask.value
                let transcript = try Self.makeRawTranscript(from: results)
                let elapsed = startedAt.duration(to: clock.now)
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                Self.logger.notice(
                    "Apple Speech final transcription completed in \(elapsedSeconds, format: .fixed(precision: 2))s for locale \(preferredLocaleIdentifier, privacy: .public)"
                )
                return transcript
            } catch is CancellationError {
                resultsTask.cancel()
                throw CancellationError()
            } catch {
                resultsTask.cancel()
                throw error
            }
        }.value
    }

    static func preflightCheck(localeIdentifier: String) async throws {
        _ = try await resolveLocale(identifier: localeIdentifier)
    }

    private static func resolveLocale(identifier: String) async throws -> Locale {
        let requested = Locale(identifier: identifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AppleSpeechTranscriptionError.localeUnavailable(identifier)
        }
        return locale
    }

    private static func openAudioFile(at audioURL: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: audioURL)
        } catch {
            throw AppleSpeechTranscriptionError.failedToReadAudio(error.localizedDescription)
        }
    }

    private static func makeRawTranscript(from results: [DictationTranscriber.Result]) throws -> RawTranscript {
        let finalizedResults = results.filter(\.isFinal)
        let sourceResults = finalizedResults.isEmpty ? results : finalizedResults

        let orderedResults = sourceResults.sorted { lhs, rhs in
            let lhsStart = CMTimeGetSeconds(lhs.range.start)
            let rhsStart = CMTimeGetSeconds(rhs.range.start)
            if lhsStart == rhsStart {
                return CMTimeGetSeconds(lhs.resultsFinalizationTime) < CMTimeGetSeconds(rhs.resultsFinalizationTime)
            }
            return lhsStart < rhsStart
        }

        var uniqueResultsByRange: [String: DictationTranscriber.Result] = [:]
        for result in orderedResults {
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            let key = "\(start)-\(end)"
            uniqueResultsByRange[key] = result
        }

        let deduplicatedResults = uniqueResultsByRange.values.sorted { lhs, rhs in
            CMTimeGetSeconds(lhs.range.start) < CMTimeGetSeconds(rhs.range.start)
        }

        let text = deduplicatedResults
            .map { String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AppleSpeechTranscriptionError.emptyTranscript
        }

        if text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil {
            logger.notice(
                "Apple Speech final transcript arrived without sentence punctuation: \(text, privacy: .public)"
            )
        }

        let durationMS = deduplicatedResults.last.map {
            Int(CMTimeGetSeconds(CMTimeRangeGetEnd($0.range)) * 1_000)
        } ?? 0

        return RawTranscript(
            text: text,
            segments: [],
            durationMS: max(0, durationMS)
        )
    }
}
