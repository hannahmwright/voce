import Foundation
import Testing
import VoceKit
@testable import Voce

@Test("Cloud refinement prompt keeps final intended correction examples explicit")
func cloudRefinementPromptIncludesFinalIntentCorrectionRules() {
    let profile = StyleProfile(
        name: "Default",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    let prompt = OpenAICloudSpeechProviderClient.buildRefinementPrompt(
        transcript: "Yesterday I went to Publix or I meant Lowes to pick up groceries",
        localeIdentifier: "en-US",
        dictionary: [],
        profile: profile,
        appContext: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    )

    #expect(prompt.system.contains("\"or I meant\""))
    #expect(prompt.system.contains("\"no actually\""))
    #expect(prompt.system.contains("keep only the final intended version"))
    #expect(prompt.system.contains("Yesterday I went to Lowes to pick up groceries."))
    #expect(prompt.system.contains("Let's do abc."))
}

// MARK: - Chunked refinement

private actor ChunkRefinementRecorder {
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var attemptsByChunk: [String: Int] = [:]

    func begin(_ chunk: String) -> Int {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        attemptsByChunk[chunk, default: 0] += 1
        return attemptsByChunk[chunk] ?? 0
    }

    func end() {
        inFlight -= 1
    }
}

private struct FakeChunkRefinementProvider: CloudSpeechProviderClient {
    let recorder: ChunkRefinementRecorder
    let failure: @Sendable (_ chunk: String, _ attempt: Int) -> Error?

    func preflightCheck(localeIdentifier: String) async throws {}

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        throw CloudDictationError.invalidResponse
    }

    func refine(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) async throws -> String {
        let attempt = await recorder.begin(transcript)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await recorder.end()
        if let error = failure(transcript, attempt) {
            throw error
        }
        return transcript.uppercased()
    }
}

private func refineInChunks(
    _ text: String,
    provider: FakeChunkRefinementProvider
) async throws -> String {
    let engine = ChunkedTranscriptRefinementEngine(
        provider: provider,
        localeIdentifier: "en-US",
        thresholdWordCount: 4,
        targetChunkWordCount: 2,
        retryBaseDelaySeconds: 0
    )
    let profile = StyleProfile(
        name: "Default",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
    return try await engine.refine(
        raw: RawTranscript(text: text, segments: [], durationMS: 0),
        profile: profile,
        lexicon: PersonalLexicon(),
        appContext: nil
    ).text
}

private let chunkedRefinementSample = (1...12)
    .map { "Sentence \($0)." }
    .joined(separator: " ")

@Test("Chunked refinement limits concurrent provider requests")
func chunkedRefinementLimitsConcurrency() async throws {
    let recorder = ChunkRefinementRecorder()
    let provider = FakeChunkRefinementProvider(recorder: recorder) { _, _ in nil }

    let refined = try await refineInChunks(chunkedRefinementSample, provider: provider)

    #expect(await recorder.maximumInFlight <= 4)
    #expect(refined.contains("SENTENCE 1."))
    #expect(refined.contains("SENTENCE 12."))
}

@Test("Chunked refinement keeps the original text of a chunk that keeps failing")
func chunkedRefinementFallsBackPerChunk() async throws {
    let recorder = ChunkRefinementRecorder()
    let provider = FakeChunkRefinementProvider(recorder: recorder) { chunk, _ in
        chunk == "Sentence 5." ? CloudDictationError.providerError("bad chunk") : nil
    }

    let refined = try await refineInChunks(chunkedRefinementSample, provider: provider)

    #expect(refined.contains("Sentence 5."))
    #expect(refined.contains("SENTENCE 4."))
    #expect(refined.contains("SENTENCE 6."))
    #expect(await recorder.attemptsByChunk["Sentence 5."] == 1)
}

@Test("Chunked refinement retries transient chunk failures")
func chunkedRefinementRetriesTransientFailures() async throws {
    let recorder = ChunkRefinementRecorder()
    let provider = FakeChunkRefinementProvider(recorder: recorder) { chunk, attempt in
        chunk == "Sentence 3." && attempt < 3 ? CloudDictationError.rateLimited : nil
    }

    let refined = try await refineInChunks(chunkedRefinementSample, provider: provider)

    #expect(refined.contains("SENTENCE 3."))
    #expect(await recorder.attemptsByChunk["Sentence 3."] == 3)
}

@Test("Chunked refinement throws when every request will fail")
func chunkedRefinementThrowsOnCredentialFailure() async {
    let recorder = ChunkRefinementRecorder()
    let provider = FakeChunkRefinementProvider(recorder: recorder) { _, _ in
        CloudDictationError.authenticationFailed
    }

    await #expect(throws: CloudDictationError.self) {
        _ = try await refineInChunks(chunkedRefinementSample, provider: provider)
    }
}
