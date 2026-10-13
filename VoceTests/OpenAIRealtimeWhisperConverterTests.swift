import AVFoundation
import XCTest
@testable import Voce

/// The ordered-send/commit sequencing in
/// `OpenAIRealtimeWhisperCaptureSession.stop()` still requires manual realtime
/// validation: dictate a long passage and release the hotkey immediately on
/// the final word, then confirm the transcript includes it.
final class OpenAIRealtimeWhisperConverterTests: XCTestCase {
    func testShippingDefaultUsesLiveTranscribe() {
        XCTAssertEqual(
            OpenAIRealtimeTranscriptionConfiguration.defaultModel,
            "gpt-live-transcribe"
        )
    }

    func testLiveTranscribeConfigurationUsesModernContextFields() throws {
        let configuration = OpenAIRealtimeTranscriptionConfiguration.payload(
            model: "gpt-live-transcribe",
            localeIdentifier: "en-US",
            hints: ["Voce", " AC-42 ", "voce", "invalid\nkeyword", "<invalid>"]
        )

        XCTAssertEqual(configuration["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(configuration["languages"] as? [String], ["en"])
        XCTAssertEqual(configuration["keywords"] as? [String], ["Voce", "AC-42"])
        XCTAssertNil(configuration["language"])
    }

    func testLegacyRealtimeWhisperConfigurationRemainsUnchanged() throws {
        let configuration = OpenAIRealtimeTranscriptionConfiguration.payload(
            model: "gpt-realtime-whisper",
            localeIdentifier: "en-US",
            hints: ["Voce"]
        )

        XCTAssertEqual(configuration["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(configuration["language"] as? String, "en")
        XCTAssertNil(configuration["languages"])
        XCTAssertNil(configuration["keywords"])
    }

    func testRealtimePCMConversionDurationAccountingForCommonBufferSizes() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        for frameCount in [1_024, 4_800, 9_600] {
            let sourceBuffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ))
            sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
            fillSineWave(sourceBuffer)

            let conversion = try XCTUnwrap(OpenAIRealtimeWhisperCaptureSession.convertToRealtimePCMData(sourceBuffer))

            XCTAssertEqual(conversion.inputFrameCount, frameCount)
            XCTAssertEqual(conversion.data.count, conversion.outputFrameCount * 2)
            let expectedFrames = Int((Double(frameCount) * 24_000 / 48_000).rounded())
            XCTAssertLessThanOrEqual(abs(conversion.outputFrameCount - expectedFrames), 1)
        }
    }

    func testChunkedRealtimePCMConversionPreservesDurationWithinConverterTolerance() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        var inputFrames = 0
        var outputFrames = 0

        for _ in 0..<120 {
            let sourceBuffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: 4_800
            ))
            sourceBuffer.frameLength = 4_800
            fillSineWave(sourceBuffer)

            let conversion = try XCTUnwrap(OpenAIRealtimeWhisperCaptureSession.convertToRealtimePCMData(sourceBuffer))
            inputFrames += conversion.inputFrameCount
            outputFrames += conversion.outputFrameCount
        }

        let expectedOutputFrames = Int((Double(inputFrames) * 24_000 / 48_000).rounded())
        XCTAssertLessThanOrEqual(abs(outputFrames - expectedOutputFrames), 120)
    }

    func testCachedConverterMatchesFreshConversionPerBuffer() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let cached = CachedPCMConverter(outputFormat: OpenAIRealtimeWhisperCaptureSession.realtimeTargetFormat)

        for _ in 0..<20 {
            let sourceBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1_024))
            sourceBuffer.frameLength = 1_024
            fillSineWave(sourceBuffer)

            let fresh = try XCTUnwrap(OpenAIRealtimeWhisperCaptureSession.convertToRealtimePCMData(sourceBuffer))
            let reused = try XCTUnwrap(OpenAIRealtimeWhisperCaptureSession.convertToRealtimePCMData(
                sourceBuffer,
                using: cached
            ))

            XCTAssertEqual(reused.outputFrameCount, fresh.outputFrameCount)
            XCTAssertEqual(reused.data, fresh.data)
        }
    }

    func testCachedConverterFollowsInputFormatChange() throws {
        let cached = CachedPCMConverter(outputFormat: OpenAIRealtimeWhisperCaptureSession.realtimeTargetFormat)
        for (sampleRate, channels) in [(48_000.0, AVAudioChannelCount(1)), (44_100.0, 2), (16_000.0, 1)] {
            let sourceFormat = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            ))
            let frameCount = Int(sampleRate / 10)
            let sourceBuffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ))
            sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
            fillSineWave(sourceBuffer)

            let conversion = try XCTUnwrap(OpenAIRealtimeWhisperCaptureSession.convertToRealtimePCMData(
                sourceBuffer,
                using: cached
            ))

            XCTAssertLessThanOrEqual(abs(conversion.outputFrameCount - 2_400), 1, "sampleRate=\(sampleRate)")
            XCTAssertEqual(conversion.data.count, conversion.outputFrameCount * 2)
        }
    }

    func testStreamingConverterPassesMatchingFormatThrough() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = StreamingPCMConverter(outputFormat: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024

        let output = try XCTUnwrap(converter.process(buffer))

        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output.first === buffer)
        XCTAssertTrue(converter.drain().isEmpty)
    }

    // After a device switch to a 24 kHz input, the capture file (48 kHz) must
    // get continuous audio: no lost frames and no seams at buffer edges.
    func testStreamingConverterResamplesContinuouslyAcrossBuffers() throws {
        let fileFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let converter = StreamingPCMConverter(outputFormat: fileFormat)
        let framesPerBuffer = 512
        var inputFrames = 0
        var samples: [Float] = []

        for bufferIndex in 0..<50 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(framesPerBuffer)
            ))
            buffer.frameLength = AVAudioFrameCount(framesPerBuffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<framesPerBuffer {
                let t = Float(bufferIndex * framesPerBuffer + frame) / 24_000
                channel[frame] = sin(2 * .pi * 440 * t) * 0.5
            }
            inputFrames += framesPerBuffer
            for output in try XCTUnwrap(converter.process(buffer)) {
                XCTAssertEqual(output.format, fileFormat)
                samples += Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
            }
        }
        for output in converter.drain() {
            samples += Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
        }

        XCTAssertLessThanOrEqual(abs(samples.count - inputFrames * 2), 4)
        // A 440 Hz sine at 0.5 amplitude moves at most ~0.03 per 48 kHz
        // sample; per-buffer resets would put larger jumps at every seam.
        let steadyState = samples.dropFirst(256).dropLast(256)
        let largestStep = zip(steadyState, steadyState.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(largestStep, 0.06)
    }

    // Simulates a wedged websocket send: the drain wait in `stop()` must
    // return after the timeout even though the send task never completes,
    // so releasing the hotkey can never hang dictation forever.
    func testWaitTimesOutWhenSendTaskNeverCompletes() async {
        let wedgedSend = Task<Void, Never> {
            // Long enough to outlive the test by a wide margin.
            try? await Task.sleep(nanoseconds: 600_000_000_000)
        }
        let start = ContinuousClock().now

        let drained = await OpenAIRealtimeWhisperCaptureSession.wait(for: wedgedSend, timeoutSeconds: 0.2)

        XCTAssertFalse(drained)
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .seconds(5))
        wedgedSend.cancel()
    }

    func testWaitReturnsTrueWhenSendTaskCompletes() async {
        let completedSend = Task<Void, Never> {}

        let drained = await OpenAIRealtimeWhisperCaptureSession.wait(for: completedSend, timeoutSeconds: 5)

        XCTAssertTrue(drained)
    }

    // The drain gate ahead of `commit()`: on timeout it must throw (so
    // `stop()` unwinds without ever invoking commit on the wedged socket)
    // and cancel the sender.
    func testEnsureDrainedThrowsOnTimeoutInsteadOfProceedingToCommit() async {
        let wedgedSend = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
        }

        do {
            try await OpenAIRealtimeWhisperCaptureSession.ensureDrained(wedgedSend, timeoutSeconds: 0.2)
            XCTFail("Expected ensureDrained to throw on timeout")
        } catch {
            XCTAssertTrue(error is CloudDictationError, "Expected CloudDictationError.timedOut, got \(error)")
        }
        XCTAssertTrue(wedgedSend.isCancelled)
    }

    func testEnsureDrainedReturnsWhenSendTaskCompletes() async throws {
        let completedSend = Task<Void, Never> {}

        try await OpenAIRealtimeWhisperCaptureSession.ensureDrained(completedSend, timeoutSeconds: 5)

        XCTAssertFalse(completedSend.isCancelled)
    }

    func testRecoveryCheckpointPersistsStreamingDeltasForNextLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpoint = try RealtimeDictationRecoveryCheckpoint(directoryURL: directory)
        checkpoint.replace(with: "This is", revision: 1, synchronize: false)
        checkpoint.replace(with: "This is still recoverable.", revision: 2, synchronize: false)
        XCTAssertEqual(checkpoint.snapshot(), "This is still recoverable.")
        checkpoint.preserveForNextLaunch()

        let recoveries = RealtimeDictationRecoveryCheckpoint.pendingRecoveries(directoryURL: directory)
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(recoveries.first?.text, "This is still recoverable.")

        RealtimeDictationRecoveryCheckpoint.discardPending(recoveries)
        XCTAssertTrue(RealtimeDictationRecoveryCheckpoint.pendingRecoveries(directoryURL: directory).isEmpty)
    }

    func testRecoveryCheckpointReplacesDeltasWithCredibleFinalTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpoint = try RealtimeDictationRecoveryCheckpoint(directoryURL: directory)
        checkpoint.replace(with: "streaming draft", revision: 1, synchronize: false)
        checkpoint.replace(with: "Final transcript.")
        checkpoint.preserveForNextLaunch()

        let recoveries = RealtimeDictationRecoveryCheckpoint.pendingRecoveries(directoryURL: directory)
        XCTAssertEqual(recoveries.first?.text, "Final transcript.")
    }

    func testSubstantiallyTruncatedCompletedTranscriptKeepsCheckpointedPartial() {
        let partial = Array(repeating: "important sentence", count: 20).joined(separator: " ")
        let completed = "important sentence"

        XCTAssertEqual(
            OpenAIRealtimeWhisperCaptureSession.preferredCompletedTranscript(
                partial: partial,
                completed: completed
            ),
            partial
        )
    }

    func testCredibleCompletedTranscriptSupersedesStreamingDraft() {
        let partial = "This is a streaming draft without punctuation"
        let completed = "This is a streaming draft, without punctuation."

        XCTAssertEqual(
            OpenAIRealtimeWhisperCaptureSession.preferredCompletedTranscript(
                partial: partial,
                completed: completed
            ),
            completed
        )
    }

    func testLongFormTranscriptPreservesSegmentOrderAcrossRollover() async {
        let transcript = RealtimeLongFormTranscript()
        let first = UUID()
        let second = UUID()

        await transcript.registerSegment(first)
        await transcript.registerSegment(second)
        await transcript.appendPartial(first, delta: "The first session")
        await transcript.appendPartial(second, delta: "continues seamlessly")
        _ = await transcript.completeSegment(first, transcript: "The first session")
        let combined = await transcript.completeSegment(
            second,
            transcript: "continues seamlessly."
        )

        XCTAssertEqual(combined, "The first session continues seamlessly.")
    }

    func testRecoveryCheckpointIgnoresStaleRevisionsAndTruncatesShorterText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpoint = try RealtimeDictationRecoveryCheckpoint(directoryURL: directory)
        checkpoint.replace(with: "A much longer partial transcript", revision: 2, synchronize: false)
        checkpoint.replace(with: "Older render", revision: 1, synchronize: false)
        XCTAssertEqual(checkpoint.snapshot(), "A much longer partial transcript")

        checkpoint.replace(with: "Final text.", revision: 3)
        checkpoint.preserveForNextLaunch()

        let recoveries = RealtimeDictationRecoveryCheckpoint.pendingRecoveries(directoryURL: directory)
        XCTAssertEqual(recoveries.first?.text, "Final text.")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers.count, 1, "Atomic replace must not leave temporary files: \(leftovers)")
    }

    // A delta from the new connection that lands while the retired segment is
    // being completed must survive in the combined transcript (and so in the
    // checkpoint rendered from it).
    func testLongFormSnapshotKeepsNewSegmentDeltasWhileRetiredSegmentCompletes() async {
        let transcript = RealtimeLongFormTranscript()
        let retired = UUID()
        let active = UUID()

        await transcript.registerSegment(retired)
        await transcript.appendPartial(retired, delta: "First half ")
        await transcript.appendPartial(retired, delta: "of the dictation")
        await transcript.registerSegment(active)
        await transcript.appendPartial(active, delta: "second half")
        let beforeCompletion = await transcript.snapshot()
        _ = await transcript.completeSegment(retired, transcript: "First half of the dictation.")
        await transcript.appendPartial(retired, delta: " ignored after completion")
        await transcript.appendPartial(active, delta: " continues")
        let snapshot = await transcript.snapshot()

        XCTAssertEqual(snapshot.text, "First half of the dictation. second half continues")
        XCTAssertGreaterThan(snapshot.revision, beforeCompletion.revision)
    }

    func testCoalescingThrottleLimitsRunsAndDeliversLatestValue() async throws {
        let box = ThrottleTestBox()
        let throttle = CoalescingThrottle(interval: 0.05) {
            box.recordRun()
        }

        for value in 1...200 {
            box.set(value)
            throttle.signal()
            if value.isMultiple(of: 20) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let (runs, lastSeen) = box.result()
        XCTAssertEqual(lastSeen, 200)
        XCTAssertGreaterThan(runs, 0)
        XCTAssertLessThan(runs, 20)

        throttle.invalidate()
        box.set(201)
        throttle.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.result().lastSeen, 200)
    }

    func testProviderLanguageCodeUsesFirstValidLanguageHint() {
        XCTAssertEqual(
            OpenAIRealtimeWhisperSpeechProviderClient.languageCode(
                fromHints: ["Voce", "Kubernetes", "de-DE", "en-US"],
                fallbackLocaleIdentifier: "fr-FR"
            ),
            "de"
        )
        XCTAssertEqual(
            OpenAIRealtimeWhisperSpeechProviderClient.languageCode(
                fromHints: ["AC-42"],
                fallbackLocaleIdentifier: "fr_FR"
            ),
            "fr"
        )
        XCTAssertEqual(
            OpenAIRealtimeWhisperSpeechProviderClient.languageCode(fromHints: [], fallbackLocaleIdentifier: ""),
            "en"
        )
    }

    // The realtime client's final-transcript wait must time out even though
    // the awaited receive task never finishes on its own.
    func testProviderTranscriptWaitTimesOut() async {
        let stuckReceive = Task<String, Error> {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            return ""
        }
        let start = ContinuousClock().now

        do {
            _ = try await OpenAIRealtimeWhisperSpeechProviderClient.value(of: stuckReceive, timeoutSeconds: 0.2)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error is CloudDictationError, "Expected CloudDictationError.timedOut, got \(error)")
        }
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .seconds(5))
        stuckReceive.cancel()
    }

    func testRolloverFailsFastOnCredentialAndQuotaErrors() {
        let nonRetryable: [Error] = [
            CloudDictationError.missingAPIKey,
            CloudDictationError.authenticationRequired,
            CloudDictationError.authenticationFailed,
            CloudDictationError.subscriptionRequired,
            CloudDictationError.hostedCloudMinutesExhausted,
            CloudDictationError.providerError("You exceeded your current quota, please check your plan.")
        ]
        for error in nonRetryable {
            XCTAssertTrue(OpenAIRealtimeWhisperCaptureSession.isNonRetryableConnectionError(error), "\(error)")
        }

        let retryable: [Error] = [
            CloudDictationError.timedOut,
            CloudDictationError.networkUnavailable,
            CloudDictationError.rateLimited,
            CloudDictationError.providerError("Internal server error"),
            URLError(.networkConnectionLost)
        ]
        for error in retryable {
            XCTAssertFalse(OpenAIRealtimeWhisperCaptureSession.isNonRetryableConnectionError(error), "\(error)")
        }
    }

    func testRealtimeConnectionRollsBeforeProviderMaximum() {
        XCTAssertLessThan(
            OpenAIRealtimeWhisperCaptureSession.connectionRolloverIntervalSeconds,
            60 * 60
        )
    }

    private func fillSineWave(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = sin(2 * .pi * 440 * Float(frame) / sampleRate) * 0.2
        }
    }
}

private final class ThrottleTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var runs = 0
    private var lastSeen = 0

    func set(_ newValue: Int) {
        lock.withLock { value = newValue }
    }

    func recordRun() {
        lock.withLock {
            runs += 1
            lastSeen = value
        }
    }

    func result() -> (runs: Int, lastSeen: Int) {
        lock.withLock { (runs, lastSeen) }
    }
}
