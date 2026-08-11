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
        checkpoint.append(delta: "This is ")
        checkpoint.append(delta: "still recoverable.")
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
        checkpoint.append(delta: "streaming draft")
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
        _ = await transcript.updatePartial(first, transcript: "The first session")
        _ = await transcript.updatePartial(second, transcript: "continues seamlessly")
        _ = await transcript.completeSegment(first, transcript: "The first session")
        let combined = await transcript.completeSegment(
            second,
            transcript: "continues seamlessly."
        )

        XCTAssertEqual(combined, "The first session continues seamlessly.")
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
