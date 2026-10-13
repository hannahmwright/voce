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
    /// Serializes every engine call (tap install and removal, start, restart
    /// after an input device change, stop) so the engine is never used from
    /// two threads at once. Lock order: `engineLock` before `stateLock`. The
    /// audio tap never takes it, and the restart path never waits on main.
    private let engineLock = NSLock()
    private let engineConfigurationQueue = DispatchQueue(
        label: "io.voceapp.voce.preview-capture.engine-configuration"
    )

    private var audioEngine: AVAudioEngine?
    private var engineConfigurationObserver: NSObjectProtocol?
    /// Bumped per configuration change so stale restart retries stop.
    private var engineRestartGeneration: UInt64 = 0
    /// Converts tap buffers to the capture file's format after an input
    /// device change, so the file and recognition request stay consistent.
    private var fileFormatConverter: StreamingPCMConverter?
    private var didLogConversionFailure = false
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
            fileFormatConverter = StreamingPCMConverter(outputFormat: audioFile.processingFormat)
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
                    self?.scheduleEngineRestart()
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
            // Keep an intentional cancel and a missing input device distinct
            // from a genuine engine start failure.
            if error is CancellationError || error is AppleSpeechPreviewError {
                throw error
            }
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }
    }

    /// Runs on the audio tap thread.
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        // After an input device change the tap delivers the new hardware
        // format, which the capture file cannot take directly.
        let converter = stateLock.withLock { fileFormatConverter }
        let fileBuffers: [AVAudioPCMBuffer]
        if let converter {
            guard let converted = converter.process(buffer) else {
                // Drop this buffer rather than end the dictation and lose
                // everything captured so far.
                let shouldLog = stateLock.withLock { () -> Bool in
                    defer { didLogConversionFailure = true }
                    return !didLogConversionFailure
                }
                if shouldLog {
                    Self.logger.error(
                        "Preview capture could not convert \(buffer.format.sampleRate, privacy: .public)Hz input to the capture file format"
                    )
                }
                return
            }
            fileBuffers = converted
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

    /// Delay before each restart attempt after a configuration change. A
    /// Bluetooth profile switch can report no input format for more than a
    /// second, so the attempts span about five seconds.
    static let engineRestartDelays: [TimeInterval] = [0, 0.25, 0.5, 1, 1.5, 2]

    /// Called on AVAudioEngine's notifying thread: only bumps the generation
    /// (superseding retries for an earlier change) and hops to the queue.
    private func scheduleEngineRestart() {
        let generation = stateLock.withLock { () -> UInt64? in
            guard !hasStopped else { return nil }
            engineRestartGeneration &+= 1
            return engineRestartGeneration
        }
        guard let generation else { return }
        engineConfigurationQueue.async { [weak self] in
            self?.restartEngineAfterConfigurationChange(generation: generation, attempt: 0)
        }
    }

    /// Restarts capture with the new input format after the engine stopped
    /// itself for a configuration change. Buffers in a new format
    /// are converted to the capture file format.
    /// If the input never comes back, capture ends but the session stays
    /// finalizable: `stop()` still delivers what was captured, and a later
    /// configuration change (the device returning) restarts capture.
    private func restartEngineAfterConfigurationChange(generation: UInt64, attempt: Int) {
        // Holding `engineLock` across `engine.start()` means `stop()` or
        // `cancel()` may wait (rarely, only after a device change) for a slow
        // Bluetooth start, but the engine is never touched from two threads
        // at once. This runs on `engineConfigurationQueue` and never waits on
        // the main thread, and the tap never takes the lock, so it cannot
        // deadlock.
        let result = engineLock.withLock { () -> Result<Void, Error>? in
            let engine = stateLock.withLock { () -> AVAudioEngine? in
                guard !hasStopped, engineRestartGeneration == generation else { return nil }
                return audioEngine
            }
            guard let engine else { return nil }
            engine.inputNode.removeTap(onBus: 0)
            do {
                try installCaptureTap(on: engine)
                engine.prepare()
                try engine.start()
                return .success(())
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                return .failure(error)
            }
        }

        let failure: Error?
        switch result {
        case .none:
            return
        case .success:
            failure = nil
        case .failure(let error):
            failure = error
        }

        guard let failure else {
            Self.logger.notice(
                "Preview capture restarted after audio configuration change (attempt \(attempt + 1, privacy: .public))"
            )
            return
        }
        Self.logger.error(
            "Preview capture restart attempt \(attempt + 1, privacy: .public) after audio configuration change failed: \(failure.localizedDescription, privacy: .public)"
        )
        let nextAttempt = attempt + 1
        guard nextAttempt < Self.engineRestartDelays.count else {
            Self.logger.error(
                "Preview capture input lost after audio configuration change; stopping will finalize the audio captured so far"
            )
            return
        }
        engineConfigurationQueue.asyncAfter(deadline: .now() + Self.engineRestartDelays[nextAttempt]) { [weak self] in
            self?.restartEngineAfterConfigurationChange(generation: generation, attempt: nextAttempt)
        }
    }

    /// Writes the audio a sample-rate converter still holds after a device
    /// change. Called once the tap is removed and before the file closes.
    private func flushFileFormatConverter() {
        guard let converter = stateLock.withLock({ fileFormatConverter }) else { return }
        let tail = converter.drain()
        guard !tail.isEmpty else { return }
        do {
            try stateLock.withLock {
                guard !hasStopped else { return }
                for fileBuffer in tail {
                    try audioFile?.write(from: fileBuffer)
                    capturedFrameCount += AVAudioFramePosition(fileBuffer.frameLength)
                }
            }
        } catch {
            Self.logger.error(
                "Preview capture could not write converted tail audio: \(error.localizedDescription, privacy: .public)"
            )
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
        flushFileFormatConverter()

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

/// Converts capture buffers to the capture file's format as one continuous
/// stream. Unlike per-buffer conversion, the resampler keeps its state
/// between buffers (input is fed with `.noDataNow`), so a sample-rate change
/// after a device switch does not leave a seam at every buffer edge. The
/// converter is drained when the input format changes again and at stop.
final class StreamingPCMConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// Returns the buffers to write for `buffer` (the buffer itself when it
    /// already matches the output format), or `nil` if conversion fails.
    func process(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer]? {
        lock.withLock {
            var output: [AVAudioPCMBuffer] = []
            if let converter, converter.inputFormat != buffer.format {
                output += drainLocked()
            }
            if buffer.format == outputFormat {
                output.append(buffer)
                return output
            }
            if converter == nil {
                guard let created = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                    return nil
                }
                converter = created
            }
            guard let converter else { return nil }
            let input = StreamingConverterInput(buffer: buffer)
            let capacity = Self.outputCapacity(for: buffer.frameLength, from: buffer.format, to: outputFormat)
            while true {
                guard let target = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    return nil
                }
                var conversionError: NSError?
                let status = converter.convert(to: target, error: &conversionError) { _, outStatus in
                    input.next(outStatus: outStatus)
                }
                guard conversionError == nil, status != .error else {
                    self.converter = nil
                    return nil
                }
                if target.frameLength > 0 {
                    output.append(target)
                }
                // `.haveData` means the output buffer filled up; keep pulling.
                if status != .haveData || target.frameLength == 0 {
                    return output
                }
            }
        }
    }

    /// Returns the frames still held by the converter, ending its stream.
    func drain() -> [AVAudioPCMBuffer] {
        lock.withLock { drainLocked() }
    }

    private func drainLocked() -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        self.converter = nil
        var output: [AVAudioPCMBuffer] = []
        while true {
            guard let target = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                return output
            }
            var conversionError: NSError?
            let status = converter.convert(to: target, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil, status != .error else { return output }
            if target.frameLength > 0 {
                output.append(target)
            }
            if status == .endOfStream || target.frameLength == 0 {
                return output
            }
        }
    }

    private static func outputCapacity(
        for frameLength: AVAudioFrameCount,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> AVAudioFrameCount {
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        return max(1_024, AVAudioFrameCount((Double(frameLength) * ratio).rounded(.up)) + 1_024)
    }
}

/// Supplies one buffer, then reports no data for now so the converter keeps
/// its state for the next buffer instead of ending the stream.
private final class StreamingConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            outStatus.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        outStatus.pointee = .haveData
        return buffer
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
