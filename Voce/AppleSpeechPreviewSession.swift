import AVFoundation
import Foundation
import OSLog
import Speech

enum AppleSpeechPreviewError: Error, LocalizedError {
    case failedToCreateOutputFile
    case failedToStartAudioEngine
    case audioWriteFailed(String)
    case missingOutputFile

    var errorDescription: String? {
        switch self {
        case .failedToCreateOutputFile:
            return "Failed to create captured-audio file."
        case .failedToStartAudioEngine:
            return "Failed to start live preview audio capture."
        case .audioWriteFailed(let details):
            return "Recording failed while writing audio: \(details)"
        case .missingOutputFile:
            return "Recording finished without a captured audio file."
        }
    }
}

struct AppleSpeechPreviewStopResult: Sendable {
    let captureURL: URL
    let captureDurationMS: Int
}

/// Uses Apple's on-device speech recognizer for low-latency partial text while
/// recording raw microphone audio to disk for the final Apple Speech pass.
final class AppleSpeechPreviewSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "AppleSpeechPreview")

    private let onPartialText: @Sendable (String) -> Void
    private let onTerminalError: @Sendable (Error) -> Void
    private let onAudioLevel: @Sendable (Double) -> Void
    private let localeIdentifier: String
    private let previewTranscriptionEnabled: Bool
    private let stateLock = NSLock()

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var hasStopped = false
    private var latestWriteError: Error?
    private var capturedFrameCount: AVAudioFramePosition = 0
    private var captureStartedAt: ContinuousClock.Instant?

    init(
        localeIdentifier: String = "en-US",
        previewTranscriptionEnabled: Bool = false,
        onPartialText: @escaping @Sendable (String) -> Void,
        onTerminalError: @escaping @Sendable (Error) -> Void = { _ in },
        onAudioLevel: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.localeIdentifier = localeIdentifier
        self.previewTranscriptionEnabled = previewTranscriptionEnabled
        self.onPartialText = onPartialText
        self.onTerminalError = onTerminalError
        self.onAudioLevel = onAudioLevel
    }

    func start() async throws {
        stateLock.withLock {
            hasStopped = false
            latestWriteError = nil
            capturedFrameCount = 0
            captureStartedAt = nil
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputURL = Self.makeOutputURL()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: outputURL, settings: inputFormat.settings)
        } catch {
            throw AppleSpeechPreviewError.failedToCreateOutputFile
        }

        self.outputURL = outputURL
        self.audioFile = audioFile

        let speechRecognitionAvailable: Bool
        if previewTranscriptionEnabled {
            let authorizationStatus = await Self.requestSpeechAuthorizationIfNeeded()
            speechRecognitionAvailable = authorizationStatus == .authorized
        } else {
            speechRecognitionAvailable = false
        }

        if speechRecognitionAvailable {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
            if let recognizer, recognizer.supportsOnDeviceRecognition {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = true

                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    guard let self else { return }

                    if let result {
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        DispatchQueue.main.async {
                            self.onPartialText(text)
                        }
                    }

                    // Ignore recognizer errors for preview-only mode. Raw audio is still
                    // being captured for the final Apple Speech transcription pass.
                    if error != nil {
                        return
                    }
                }

                speechRecognizer = recognizer
                recognitionRequest = request
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            do {
                try self.stateLock.withLock {
                    guard !self.hasStopped else { return }
                    try self.audioFile?.write(from: buffer)
                    self.capturedFrameCount += AVAudioFramePosition(buffer.frameLength)
                }
            } catch {
                self.recordTerminalError(AppleSpeechPreviewError.audioWriteFailed(error.localizedDescription))
            }

            self.recognitionRequest?.append(buffer)
            self.onAudioLevel(Self.normalizedAudioLevel(from: buffer))
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.audioFile = nil
            self.outputURL = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }

        audioEngine = engine
        stateLock.withLock {
            captureStartedAt = ContinuousClock().now
        }
    }

    func stop() throws -> AppleSpeechPreviewStopResult {
        let outputURL: URL?
        let capturedFrameCount: AVAudioFramePosition
        let wallDurationSeconds: Double?

        // Remove the tap before marking the session stopped. Marking first can
        // drop the final in-flight buffer, which sounds like missing tail words.
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil

        let stoppedAt = ContinuousClock().now
        (outputURL, capturedFrameCount, wallDurationSeconds) = stateLock.withLock {
            hasStopped = true
            let wallDurationSeconds = captureStartedAt.map { start in
                let duration = start.duration(to: stoppedAt)
                return Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
            }
            let outputURL = self.outputURL
            let capturedFrameCount = self.capturedFrameCount
            audioFile = nil
            captureStartedAt = nil
            return (outputURL, capturedFrameCount, wallDurationSeconds)
        }

        if let latestWriteError {
            cleanupOutputFile(at: outputURL)
            throw latestWriteError
        }

        guard let outputURL else {
            throw AppleSpeechPreviewError.missingOutputFile
        }

        let captureDurationMS = Self.captureDurationMS(for: outputURL)
        let wallDurationDescription = wallDurationSeconds.map { "\($0.formatted(.number.precision(.fractionLength(2))))s" } ?? "unknown"
        let fileDurationSeconds = Double(captureDurationMS) / 1_000
        Self.logger.notice(
            "Preview capture stopped; wall=\(wallDurationDescription, privacy: .public) file=\(fileDurationSeconds, format: .fixed(precision: 2))s frames=\(capturedFrameCount, privacy: .public)"
        )
        self.outputURL = nil
        return AppleSpeechPreviewStopResult(
            captureURL: outputURL,
            captureDurationMS: captureDurationMS
        )
    }

    func cancel() {
        let outputURL = stateLock.withLock {
            hasStopped = true
            return self.outputURL
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil

        stateLock.withLock {
            audioFile = nil
            self.outputURL = nil
            latestWriteError = nil
            capturedFrameCount = 0
            captureStartedAt = nil
        }

        cleanupOutputFile(at: outputURL)
    }

    private func recordTerminalError(_ error: Error) {
        let shouldNotify = stateLock.withLock { () -> Bool in
            guard latestWriteError == nil else { return false }
            latestWriteError = error
            return true
        }
        guard shouldNotify else { return }

        DispatchQueue.main.async {
            self.onTerminalError(error)
        }
    }

    private func cleanupOutputFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-live-preview-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private static func captureDurationMS(for url: URL) -> Int {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return 0 }
        let durationSeconds = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)
        return Int((durationSeconds * 1_000).rounded())
    }

    private static func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sumSquares += sample * sample
            }
            sampleCount += frameCount
        }

        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Float(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let clipped = max(-55, min(0, decibels))
        return Double((clipped + 55) / 55)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
