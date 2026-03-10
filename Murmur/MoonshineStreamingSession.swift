import AVFoundation
import Foundation
import MoonshineVoice
import MurmurKit

/// Manages concurrent audio capture and streaming Moonshine transcription.
///
/// Audio is captured via AVAudioEngine and fed to Moonshine's streaming API
/// in real-time. Partial transcript text is published to the main thread
/// as Moonshine processes audio chunks.
final class MoonshineStreamingSession: @unchecked Sendable {
    struct Configuration: Sendable {
        var modelDirectoryPath: String
        var modelArch: MoonshineModelPreset
    }

    private let config: Configuration
    private let onPartialText: @Sendable (String) -> Void

    // Accessed only on processingQueue
    private let processingQueue = DispatchQueue(label: "murmur.moonshine-stream", qos: .userInitiated)
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var pendingBuffers: [[Float]] = []
    private var isStopped = false

    // Accessed on main thread (start/stop called from MainActor)
    private var audioEngine: AVAudioEngine?
    private var drainTimer: DispatchSourceTimer?

    init(config: Configuration, onPartialText: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.onPartialText = onPartialText
    }

    /// Starts audio capture and streaming transcription.
    /// Must be called from the main thread.
    func start() throws {
        // Initialize Moonshine on the processing queue (synchronous).
        try processingQueue.sync {
            let t = try Transcriber(
                modelPath: config.modelDirectoryPath,
                modelArch: config.modelArch.moonshineArch
            )
            let s = try t.createStream(updateInterval: 0.3)
            try s.start()
            self.transcriber = t
            self.stream = s
        }

        // Set up AVAudioEngine for mic capture.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Converter: native mic format → 16 kHz mono float32.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw MoonshineTranscriptionError.unsupportedAudioFormat
        }

        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)

        // Install tap – copy samples as fast as possible off the realtime thread.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertBuffer(buffer, converter: converter, targetFormat: targetFormat)
            guard !samples.isEmpty else { return }
            self.processingQueue.async { [weak self] in
                self?.pendingBuffers.append(samples)
            }
        }

        try engine.start()
        self.audioEngine = engine

        // Drain buffered audio every 100 ms and feed to Moonshine.
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.drainBuffers()
        }
        timer.resume()
        self.drainTimer = timer
    }

    /// Stops capture, finalises the transcript, and returns the result.
    /// Must be called from the main thread.
    func stop() -> RawTranscript {
        tearDownAudio()

        return processingQueue.sync {
            isStopped = true

            // Process any remaining audio.
            drainBuffersUnsafe()

            do {
                try stream?.stop()
                let transcript = try stream?.updateTranscription(
                    flags: TranscribeStreamFlags.flagForceUpdate
                )
                stream?.close()
                transcriber?.close()
                stream = nil
                transcriber = nil

                guard let transcript else {
                    return RawTranscript(text: "")
                }
                return Self.buildRawTranscript(from: transcript)
            } catch {
                stream?.close()
                transcriber?.close()
                stream = nil
                transcriber = nil
                return RawTranscript(text: "")
            }
        }
    }

    /// Cancels without producing a transcript.
    func cancel() {
        tearDownAudio()
        processingQueue.sync {
            isStopped = true
            stream?.close()
            transcriber?.close()
            stream = nil
            transcriber = nil
        }
    }

    // MARK: - Audio Conversion

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        guard let converter else {
            // Formats match; just copy.
            guard let ch = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var didSupply = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if didSupply {
                outStatus.pointee = .endOfStream
                return nil
            }
            didSupply = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    // MARK: - Buffer Drain (processingQueue)

    private func drainBuffers() {
        drainBuffersUnsafe()
    }

    private func drainBuffersUnsafe() {
        guard !pendingBuffers.isEmpty, !isStopped else { return }

        let buffers = pendingBuffers
        pendingBuffers.removeAll(keepingCapacity: true)

        let allSamples = buffers.flatMap { $0 }
        guard !allSamples.isEmpty else { return }

        do {
            try stream?.addAudio(allSamples, sampleRate: 16_000)
            if let transcript = try stream?.updateTranscription() {
                let text = transcript.lines
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let captured = text
                    DispatchQueue.main.async { [weak self] in
                        self?.onPartialText(captured)
                    }
                }
            }
        } catch {
            // Partial failures are acceptable during streaming.
        }
    }

    // MARK: - Tear Down

    private func tearDownAudio() {
        drainTimer?.cancel()
        drainTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Transcript Building

    private static func buildRawTranscript(from transcript: Transcript) -> RawTranscript {
        let segments = transcript.lines.map { line in
            TranscriptSegment(
                startMS: Int(line.startTime * 1_000),
                endMS: Int((line.startTime + line.duration) * 1_000),
                text: line.text
            )
        }

        let text = transcript.lines
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let durationMS = Int(
            (transcript.lines.last.map { $0.startTime + $0.duration } ?? 0) * 1_000
        )
        return RawTranscript(text: text, segments: segments, durationMS: durationMS)
    }
}
