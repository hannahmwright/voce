import AVFoundation
import Foundation
import OSLog
import Speech

enum AppleSpeechPreviewError: Error, LocalizedError {
    case failedToCreateOutputFile
    case failedToStartAudioEngine
    case audioWriteFailed(String)
    case missingOutputFile
    case audioInputUnavailable

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
        case .audioInputUnavailable:
            return "Recording stopped because the microphone changed or became unavailable."
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
    /// Serializes engine lifecycle work (start, restart after an input device
    /// change, teardown). Lock order: `engineLock` before `stateLock`. The
    /// audio tap never takes it.
    private let engineLock = NSLock()
    private let engineConfigurationQueue = DispatchQueue(
        label: "io.voceapp.voce.preview-capture.engine-configuration"
    )

    private var audioEngine: AVAudioEngine?
    private var engineConfigurationObserver: NSObjectProtocol?
    /// Converts tap buffers to the capture file's format after an input
    /// device change, so the file and recognition request stay consistent.
    private var fileFormatConverter: CachedPCMConverter?
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
            cleanupOutputFile(at: outputURL)
            throw AppleSpeechPreviewError.failedToCreateOutputFile
        }

        stateLock.withLock {
            self.outputURL = outputURL
            self.audioFile = audioFile
            fileFormatConverter = CachedPCMConverter(outputFormat: audioFile.processingFormat)
        }

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
                stateLock.withLock {
                    recognitionRequest = request
                }
            }
        }

        do {
            try engineLock.withLock {
                try installCaptureTap(on: engine)
                do {
                    try engine.start()
                } catch {
                    engine.inputNode.removeTap(onBus: 0)
                    throw error
                }
                // When the input device changes the engine stops itself and
                // posts this; without handling it audio silently ends.
                let observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    guard let self else { return }
                    // Leave AVAudioEngine's notifying thread before touching
                    // the engine or taking `engineLock`.
                    self.engineConfigurationQueue.async {
                        self.handleEngineConfigurationChange(attempt: 1)
                    }
                }
                let installed = stateLock.withLock { () -> Bool in
                    guard !hasStopped else { return false }
                    audioEngine = engine
                    engineConfigurationObserver = observer
                    captureStartedAt = ContinuousClock().now
                    return true
                }
                guard installed else {
                    // `cancel()` ran while speech authorization was pending.
                    NotificationCenter.default.removeObserver(observer)
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    throw CancellationError()
                }
            }
        } catch {
            let staleOutputURL = stateLock.withLock { () -> URL? in
                defer {
                    self.audioFile = nil
                    self.outputURL = nil
                    recognitionRequest = nil
                }
                return self.outputURL
            }
            recognitionTask?.cancel()
            recognitionTask = nil
            speechRecognizer = nil
            cleanupOutputFile(at: staleOutputURL)
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }
    }

    /// Runs on the audio tap thread.
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        let converter = stateLock.withLock { fileFormatConverter }
        var fileBuffers: [AVAudioPCMBuffer] = []
        if let converter, buffer.format != converter.outputFormat {
            // After an input device change the tap delivers the new hardware
            // format, which the capture file cannot take directly.
            guard converter.convert(buffer, { fileBuffers.append($0) }) else {
                recordTerminalError(AppleSpeechPreviewError.audioInputUnavailable)
                return
            }
        } else {
            fileBuffers = [buffer]
        }

        do {
            try stateLock.withLock {
                guard !hasStopped else { return }
                for fileBuffer in fileBuffers {
                    try audioFile?.write(from: fileBuffer)
                    capturedFrameCount += AVAudioFramePosition(fileBuffer.frameLength)
                }
            }
        } catch {
            recordTerminalError(AppleSpeechPreviewError.audioWriteFailed(error.localizedDescription))
        }

        // `stop()` clears the request on another thread.
        if let request = stateLock.withLock({ recognitionRequest }) {
            fileBuffers.forEach { request.append($0) }
        }
        onAudioLevel(Self.normalizedAudioLevel(from: buffer))
    }

    /// Installs the capture tap using the input node's current format.
    /// Must be called with `engineLock` held.
    private func installCaptureTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        // A zero rate or channel count means there is no usable input device;
        // installing a tap with it raises an Objective-C exception.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AppleSpeechPreviewError.audioInputUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }
    }

    /// Restarts capture after the engine stopped itself for a configuration
    /// change. If the input stays unusable, reports a terminal error so the
    /// controller ends the dictation instead of finalizing truncated audio.
    private func handleEngineConfigurationChange(attempt: Int) {
        let maximumAttempts = 3
        let result = engineLock.withLock { () -> Result<Void, Error>? in
            guard let engine = stateLock.withLock({ hasStopped ? nil : audioEngine }) else {
                return nil
            }
            engine.inputNode.removeTap(onBus: 0)
            do {
                try installCaptureTap(on: engine)
                engine.prepare()
                try engine.start()
                return .success(())
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                return .failure(error)
            }
        }
        guard let result else { return }
        guard case .failure(let error) = result else {
            Self.logger.notice("Preview capture restarted after audio configuration change")
            return
        }
        Self.logger.error(
            "Preview capture restart attempt \(attempt, privacy: .public) after audio configuration change failed: \(error.localizedDescription, privacy: .public)"
        )
        if attempt < maximumAttempts {
            engineConfigurationQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.handleEngineConfigurationChange(attempt: attempt + 1)
            }
        } else {
            recordTerminalError(AppleSpeechPreviewError.audioInputUnavailable)
        }
    }

    private func stopAudioEngine() {
        let observer = engineLock.withLock { () -> NSObjectProtocol? in
            let (engine, observer) = stateLock.withLock { () -> (AVAudioEngine?, NSObjectProtocol?) in
                defer {
                    audioEngine = nil
                    engineConfigurationObserver = nil
                }
                return (audioEngine, engineConfigurationObserver)
            }
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            return observer
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func stop() throws -> AppleSpeechPreviewStopResult {
        let outputURL: URL?
        let capturedFrameCount: AVAudioFramePosition
        let wallDurationSeconds: Double?

        // Remove the tap before marking the session stopped. Marking first can
        // drop the final in-flight buffer, which sounds like missing tail words.
        stopAudioEngine()

        let recognitionRequest = stateLock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.recognitionRequest = nil }
            return self.recognitionRequest
        }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        speechRecognizer = nil

        let stoppedAt = ContinuousClock().now
        let latestWriteError: Error?
        (outputURL, capturedFrameCount, wallDurationSeconds, latestWriteError) = stateLock.withLock {
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
            self.outputURL = nil
            return (outputURL, capturedFrameCount, wallDurationSeconds, self.latestWriteError)
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

        stopAudioEngine()

        let recognitionRequest = stateLock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.recognitionRequest = nil }
            return self.recognitionRequest
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
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
