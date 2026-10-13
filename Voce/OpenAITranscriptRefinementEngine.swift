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
    private let maximumConcurrentRequests: Int
    private let maximumAttemptsPerChunk: Int
    private let retryBaseDelaySeconds: TimeInterval
    private let overallDeadlineSeconds: TimeInterval

    init(
        provider: any CloudSpeechProviderClient,
        localeIdentifier: String,
        thresholdWordCount: Int = 120,
        targetChunkWordCount: Int = 80,
        maximumConcurrentRequests: Int = 8,
        maximumAttemptsPerChunk: Int = 3,
        retryBaseDelaySeconds: TimeInterval = 0.5,
        overallDeadlineSeconds: TimeInterval = 50
    ) {
        self.provider = provider
        self.localeIdentifier = localeIdentifier
        self.thresholdWordCount = max(2, thresholdWordCount)
        self.targetChunkWordCount = max(1, targetChunkWordCount)
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.maximumAttemptsPerChunk = max(1, maximumAttemptsPerChunk)
        self.retryBaseDelaySeconds = max(0, retryBaseDelaySeconds)
        self.overallDeadlineSeconds = max(0.1, overallDeadlineSeconds)
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

        let refinedChunks = try await refineChunks(
            chunks,
            profile: profile,
            lexicon: lexicon,
            appContext: appContext
        )

        let refined = Self.normalizeText(refinedChunks.joined(separator: "\n\n"))
        Self.logger.notice(
            "Chunked transcript refinement completed in \(Self.seconds(from: startedAt.duration(to: clock.now)), format: .fixed(precision: 2))s [outputChars=\(refined.count, privacy: .public)]"
        )
        return Self.cleanTranscript(rawText: raw.text, refinedText: refined)
    }

    private enum ChunkOutcome: Sendable {
        case chunk(index: Int, result: Result<String, Error>)
        case deadline
    }

    /// Refines chunks with bounded concurrency under one overall deadline, so
    /// a slow backend costs about as long as one request did before chunking
    /// rather than minutes. A chunk that fails, or is still running at the
    /// deadline, keeps its original text, so one bad request no longer throws
    /// away every other refined chunk. Errors that will fail every request,
    /// failure of the whole first wave, or no chunk refined by the deadline
    /// still throw so the caller's whole-transcript fallback runs.
    private func refineChunks(
        _ chunks: [String],
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext?
    ) async throws -> [String] {
        let provider = provider
        let localeIdentifier = localeIdentifier
        let maximumAttempts = maximumAttemptsPerChunk
        let retryBaseDelay = retryBaseDelaySeconds
        let deadlineNanoseconds = UInt64(overallDeadlineSeconds * 1_000_000_000)
        let firstWaveSize = min(maximumConcurrentRequests, chunks.count)
        var refinedChunks = chunks
        var refinedChunkCount = 0
        var failedChunkCount = 0
        var firstWaveFailureCount = 0
        var lastError: Error?
        var reachedDeadline = false

        try await withThrowingTaskGroup(of: ChunkOutcome.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                return .deadline
            }

            var nextIndex = 0
            var chunksInFlight = 0
            func fillAvailableSlots() {
                while chunksInFlight < firstWaveSize, nextIndex < chunks.count {
                    addNextChunk()
                }
            }
            func addNextChunk() {
                let index = nextIndex
                let chunk = chunks[index]
                nextIndex += 1
                chunksInFlight += 1
                group.addTask {
                    do {
                        let refined = try await Self.refineWithRetry(
                            maximumAttempts: maximumAttempts,
                            retryBaseDelaySeconds: retryBaseDelay
                        ) {
                            try await provider.refine(
                                transcript: chunk,
                                localeIdentifier: localeIdentifier,
                                dictionary: lexicon.entries,
                                profile: profile,
                                appContext: appContext
                            )
                        }
                        return .chunk(index: index, result: .success(refined))
                    } catch {
                        return .chunk(index: index, result: .failure(error))
                    }
                }
            }

            fillAvailableSlots()

            var finishedChunkCount = 0
            while finishedChunkCount < chunks.count, let outcome = try await group.next() {
                guard case .chunk(let index, let result) = outcome else {
                    // The deadline sleeper also returns early when the caller
                    // is cancelled; that is a cancellation, not a timeout.
                    if Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    // Unfinished chunks keep their original text. Cancelling
                    // also cancels their in-flight requests.
                    reachedDeadline = true
                    break
                }
                finishedChunkCount += 1
                chunksInFlight -= 1
                switch result {
                case .success(let refined):
                    refinedChunks[index] = refined
                    refinedChunkCount += 1
                case .failure(let error):
                    if Task.isCancelled || error is CancellationError || Self.failsEveryRequest(error) {
                        group.cancelAll()
                        throw error
                    }
                    failedChunkCount += 1
                    lastError = error
                    if index < firstWaveSize {
                        firstWaveFailureCount += 1
                    }
                    Self.logger.error(
                        "Chunk \(index, privacy: .public) refinement failed; keeping its original text: \(error.localizedDescription, privacy: .public)"
                    )
                    // If nothing in the first wave succeeded, the backend is
                    // unhealthy: stop instead of working through every chunk.
                    if firstWaveFailureCount == firstWaveSize, refinedChunkCount == 0 {
                        group.cancelAll()
                        throw error
                    }
                }
                // Until some chunk succeeds, failures do not start new
                // requests, so an unhealthy backend sees only the first wave.
                if refinedChunkCount > 0 {
                    fillAvailableSlots()
                }
            }
            group.cancelAll()
        }

        try Task.checkCancellation()
        if reachedDeadline {
            Self.logger.error(
                "Chunked refinement reached its deadline; \(chunks.count - refinedChunkCount, privacy: .public) of \(chunks.count, privacy: .public) chunks keep their original text"
            )
            if refinedChunkCount == 0 {
                throw lastError ?? CloudDictationError.timedOut
            }
        } else if failedChunkCount == chunks.count, let lastError {
            throw lastError
        }
        return refinedChunks
    }

    static func refineWithRetry(
        maximumAttempts: Int,
        retryBaseDelaySeconds: TimeInterval,
        operation: @Sendable () async throws -> String
    ) async throws -> String {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maximumAttempts, isTransient(error) else {
                    throw error
                }
                let delay = retryBaseDelaySeconds * pow(2, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Timeouts are not retried: each request already waited up to 45
    /// seconds, and the overall deadline bounds the rest. Quota exhaustion
    /// arrives as a non-retryable `providerError`, not `rateLimited`.
    static func isTransient(_ error: Error) -> Bool {
        switch error as? CloudDictationError {
        case .rateLimited, .networkUnavailable:
            return true
        default:
            return false
        }
    }

    static func failsEveryRequest(_ error: Error) -> Bool {
        switch error as? CloudDictationError {
        case .missingAPIKey,
             .authenticationRequired,
             .authenticationFailed,
             .subscriptionRequired,
             .hostedCloudMinutesExhausted:
            return true
        case .providerError(let message):
            return CloudDictationError.isQuotaExhaustedMessage(message)
        default:
            return false
        }
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
