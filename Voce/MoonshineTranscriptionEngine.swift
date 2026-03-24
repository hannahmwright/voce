@preconcurrency import AVFoundation
import Foundation
import MoonshineVoice
import VoceKit

enum MoonshineTranscriptionError: Error, LocalizedError {
    case microphonePermissionDenied
    case modelDirectoryNotFound(path: String)
    case missingModelFiles([String])
    case failedToReadAudio(String)
    case unsupportedAudioFormat
    case emptyLiveTranscript
    case liveCaptureOverloaded(bufferedDuration: TimeInterval, maximumBufferedDuration: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .modelDirectoryNotFound(let path):
            return "Moonshine model directory not found at: \(path)"
        case .missingModelFiles(let files):
            return "Moonshine model is missing files: \(files.joined(separator: ", "))"
        case .failedToReadAudio(let details):
            return "Failed to read audio for Moonshine transcription: \(details)"
        case .unsupportedAudioFormat:
            return "Audio conversion to 16 kHz mono failed"
        case .emptyLiveTranscript:
            return "No speech was captured from the microphone"
        case .liveCaptureOverloaded(let bufferedDuration, let maximumBufferedDuration):
            return String(
                format: "Live transcription fell behind by %.1f seconds of queued audio (limit %.1f s). Try a shorter dictation or close heavy apps.",
                bufferedDuration,
                maximumBufferedDuration
            )
        }
    }
}

struct MoonshineTranscriptionEngine: TranscriptionEngine, Sendable {
    struct Configuration: Sendable {
        var modelDirectoryPath: String
        var modelArch: MoonshineModelPreset
        var keepModelWarm: Bool = true
    }

    private let config: Configuration

    init(config: Configuration) {
        self.config = config
    }

    func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        let configuration = config
        return try await Task.detached(priority: .userInitiated) {
            try Self.preflightCheck(
                modelDirectoryPath: configuration.modelDirectoryPath,
                modelArch: configuration.modelArch
            )

            let audio = try Self.loadAudioSamples(from: audioURL)
            let transcriber: Transcriber
            if configuration.keepModelWarm {
                transcriber = try MoonshineTranscriberCache.shared.transcriber(for: configuration)
            } else {
                transcriber = try Transcriber(
                    modelPath: configuration.modelDirectoryPath,
                    modelArch: configuration.modelArch.moonshineArch
                )
            }
            defer {
                if !configuration.keepModelWarm {
                    transcriber.close()
                }
            }

            let transcript = try transcriber.transcribeWithoutStreaming(
                audioData: audio.samples,
                sampleRate: audio.sampleRate
            )

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

            let durationMS = Int((transcript.lines.last.map { $0.startTime + $0.duration } ?? 0) * 1_000)
            return RawTranscript(text: text, segments: segments, durationMS: durationMS)
        }.value
    }

    static func preflightCheck(modelDirectoryPath: String, modelArch: MoonshineModelPreset) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MoonshineTranscriptionError.modelDirectoryNotFound(path: modelDirectoryPath)
        }

        let missing = MoonshineModelPaths.missingFiles(in: modelDirectoryPath, preset: modelArch)
        guard missing.isEmpty else {
            throw MoonshineTranscriptionError.missingModelFiles(missing)
        }

        let transcriber = try Transcriber(modelPath: modelDirectoryPath, modelArch: modelArch.moonshineArch)
        transcriber.close()
    }

    private static func loadAudioSamples(from audioURL: URL) throws -> (samples: [Float], sampleRate: Int32) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw MoonshineTranscriptionError.failedToReadAudio(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        // Keep the captured sample rate intact and let Moonshine resample
        // internally. The live path already does this because app-side
        // 24 kHz -> 16 kHz conversion hurt Bluetooth mic amplitude.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MoonshineTranscriptionError.unsupportedAudioFormat
        }

        let inputCapacity = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw MoonshineTranscriptionError.failedToReadAudio("Failed to allocate input buffer")
        }

        do {
            try file.read(into: inputBuffer)
        } catch {
            throw MoonshineTranscriptionError.failedToReadAudio(error.localizedDescription)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MoonshineTranscriptionError.unsupportedAudioFormat
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw MoonshineTranscriptionError.failedToReadAudio("Failed to allocate output buffer")
        }

        let conversionState = AudioConversionInputState(inputBuffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if conversionState.didSupplyInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            conversionState.didSupplyInput = true
            outStatus.pointee = .haveData
            return conversionState.inputBuffer
        }

        if let conversionError {
            throw MoonshineTranscriptionError.failedToReadAudio(conversionError.localizedDescription)
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData?[0] else {
            throw MoonshineTranscriptionError.unsupportedAudioFormat
        }

        let frameLength = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        return (samples, Int32(outputFormat.sampleRate.rounded()))
    }
}

private final class AudioConversionInputState: @unchecked Sendable {
    let inputBuffer: AVAudioPCMBuffer

    private let lock = NSLock()
    private var storedDidSupplyInput = false

    init(inputBuffer: AVAudioPCMBuffer) {
        self.inputBuffer = inputBuffer
    }

    var didSupplyInput: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDidSupplyInput
        }
        set {
            lock.lock()
            storedDidSupplyInput = newValue
            lock.unlock()
        }
    }
}
