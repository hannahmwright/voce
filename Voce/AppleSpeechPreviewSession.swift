import AVFoundation
import Foundation
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

struct CapturedAudioChunk: Sendable {
    let index: Int
    let url: URL
    let durationMS: Int
    let leadingOverlapMS: Int
}

struct AppleSpeechPreviewStopResult: Sendable {
    let captureURL: URL
    let finalChunk: CapturedAudioChunk?
    let totalChunkCount: Int
}

/// Uses Apple's on-device speech recognizer for low-latency partial text while
/// recording raw microphone audio to disk for the final Moonshine pass.
final class AppleSpeechPreviewSession: @unchecked Sendable {
    private static let rollingChunkDuration: TimeInterval = 8.0
    private static let rollingChunkMaximumDuration: TimeInterval = 12.0
    private static let rollingChunkOverlapDuration: TimeInterval = 1.5
    private static let minimumSilenceThreshold: Float = 0.002
    private static let maximumSilenceThreshold: Float = 0.02
    private static let adaptiveSilenceMultiplier: Float = 2.5
    private static let noiseFloorSampleLimit = 120

    private let onPartialText: @Sendable (String) -> Void
    private let onSealedChunk: @Sendable (CapturedAudioChunk) -> Void
    private let onTerminalError: @Sendable (Error) -> Void
    private let stateLock = NSLock()

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var hasStopped = false
    private var latestWriteError: Error?
    private var activeChunkFile: AVAudioFile?
    private var activeChunkURL: URL?
    private var activeChunkIndex = 0
    private var activeChunkFrameCount: AVAudioFramePosition = 0
    private var activeChunkSampleRate: Double = 0
    private var activeChunkLastActivityRMS: Float = 0
    private var recentActivityRMSValues: [Float] = []
    private var recentOverlapBuffers: [PCMBufferSnapshot] = []
    private var recentOverlapDuration: TimeInterval = 0

    init(
        onPartialText: @escaping @Sendable (String) -> Void,
        onSealedChunk: @escaping @Sendable (CapturedAudioChunk) -> Void = { _ in },
        onTerminalError: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.onPartialText = onPartialText
        self.onSealedChunk = onSealedChunk
        self.onTerminalError = onTerminalError
    }

    func start() async throws {
        stateLock.withLock {
            hasStopped = false
            latestWriteError = nil
            recentActivityRMSValues.removeAll(keepingCapacity: true)
            recentOverlapBuffers.removeAll(keepingCapacity: true)
            recentOverlapDuration = 0
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
        try prepareActiveChunkFile(inputFormat: inputFormat)

        let authorizationStatus = await Self.requestSpeechAuthorizationIfNeeded()
        let speechRecognitionAvailable = authorizationStatus == .authorized

        if speechRecognitionAvailable {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
                    // being captured for the final Moonshine transcription pass.
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

            let (isStopped, audioFile) = self.stateLock.withLock {
                (self.hasStopped, self.audioFile)
            }
            guard !isStopped else { return }

            do {
                try audioFile?.write(from: buffer)
                try self.writeToActiveChunk(buffer)
                self.noteRecentOverlapBuffer(buffer)
            } catch {
                self.recordTerminalError(AppleSpeechPreviewError.audioWriteFailed(error.localizedDescription))
            }

            self.recognitionRequest?.append(buffer)
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
    }

    func stop() throws -> AppleSpeechPreviewStopResult {
        let outputURL: URL?

        outputURL = stateLock.withLock {
            hasStopped = true
            return self.outputURL
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil

        stateLock.withLock {
            audioFile = nil
        }

        if let latestWriteError {
            cleanupOutputFile(at: outputURL)
            throw latestWriteError
        }

        guard let outputURL else {
            throw AppleSpeechPreviewError.missingOutputFile
        }

        let finalChunk = try sealActiveChunk()
        let totalChunkCount = finalChunk.map { $0.index + 1 } ?? activeChunkIndex
        self.outputURL = nil
        return AppleSpeechPreviewStopResult(
            captureURL: outputURL,
            finalChunk: finalChunk,
            totalChunkCount: totalChunkCount
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
            activeChunkFile = nil
            activeChunkURL = nil
            activeChunkFrameCount = 0
            recentOverlapBuffers.removeAll(keepingCapacity: true)
            recentOverlapDuration = 0
            recentActivityRMSValues.removeAll(keepingCapacity: true)
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

    private func prepareActiveChunkFile(inputFormat: AVAudioFormat) throws {
        let chunkURL = Self.makeChunkURL(index: activeChunkIndex)
        do {
            activeChunkFile = try AVAudioFile(forWriting: chunkURL, settings: inputFormat.settings)
            activeChunkURL = chunkURL
            activeChunkFrameCount = 0
            activeChunkSampleRate = inputFormat.sampleRate
            activeChunkLastActivityRMS = 0
            try seedChunkWithOverlap()
        } catch {
            throw AppleSpeechPreviewError.failedToCreateOutputFile
        }
    }

    private func writeToActiveChunk(_ buffer: AVAudioPCMBuffer) throws {
        try activeChunkFile?.write(from: buffer)
        activeChunkFrameCount += AVAudioFramePosition(buffer.frameLength)
        activeChunkLastActivityRMS = Self.windowedActivityRMS(for: buffer)
        noteRecentActivityRMS(activeChunkLastActivityRMS)

        let bufferedDuration = Double(activeChunkFrameCount) / max(activeChunkSampleRate, 1)
        guard bufferedDuration >= Self.rollingChunkDuration else { return }
        let adaptiveSilenceThreshold = currentAdaptiveSilenceThreshold()
        guard bufferedDuration >= Self.rollingChunkMaximumDuration
            || activeChunkLastActivityRMS < adaptiveSilenceThreshold else { return }

        if let sealedChunk = try sealActiveChunk() {
            onSealedChunk(sealedChunk)
        }

        if let audioEngine {
            try prepareActiveChunkFile(inputFormat: audioEngine.inputNode.inputFormat(forBus: 0))
        }
    }

    private func sealActiveChunk() throws -> CapturedAudioChunk? {
        guard let activeChunkURL else { return nil }

        let durationMS = Int((Double(activeChunkFrameCount) / max(activeChunkSampleRate, 1)) * 1_000)
        let leadingOverlapMS = activeChunkIndex == 0 ? 0 : Int(Self.rollingChunkOverlapDuration * 1_000)
        let chunkURL = activeChunkURL
        activeChunkFile = nil
        self.activeChunkURL = nil
        activeChunkFrameCount = 0
        activeChunkLastActivityRMS = 0

        guard durationMS > 0 else {
            cleanupOutputFile(at: chunkURL)
            return nil
        }

        defer { activeChunkIndex += 1 }
        return CapturedAudioChunk(
            index: activeChunkIndex,
            url: chunkURL,
            durationMS: durationMS,
            leadingOverlapMS: min(leadingOverlapMS, durationMS)
        )
    }

    private func noteRecentOverlapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let snapshot = PCMBufferSnapshot.make(from: buffer) else { return }
        recentOverlapBuffers.append(snapshot)
        recentOverlapDuration += snapshot.duration

        while recentOverlapDuration > Self.rollingChunkOverlapDuration, !recentOverlapBuffers.isEmpty {
            let removed = recentOverlapBuffers.removeFirst()
            recentOverlapDuration -= removed.duration
        }
    }

    private func noteRecentActivityRMS(_ rms: Float) {
        recentActivityRMSValues.append(rms)
        if recentActivityRMSValues.count > Self.noiseFloorSampleLimit {
            recentActivityRMSValues.removeFirst(recentActivityRMSValues.count - Self.noiseFloorSampleLimit)
        }
    }

    private func currentAdaptiveSilenceThreshold() -> Float {
        guard !recentActivityRMSValues.isEmpty else { return Self.minimumSilenceThreshold }

        let sorted = recentActivityRMSValues.sorted()
        let percentileIndex = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * 0.2)))
        let noiseFloorEstimate = sorted[percentileIndex]
        let adaptiveThreshold = max(
            Self.minimumSilenceThreshold,
            min(Self.maximumSilenceThreshold, noiseFloorEstimate * Self.adaptiveSilenceMultiplier)
        )
        return adaptiveThreshold
    }

    private func seedChunkWithOverlap() throws {
        guard activeChunkIndex > 0 else { return }
        for snapshot in recentOverlapBuffers {
            guard let buffer = snapshot.makePCMBuffer() else { continue }
            try activeChunkFile?.write(from: buffer)
            activeChunkFrameCount += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-live-preview-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private static func makeChunkURL(index: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-live-chunk-\(index)-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private static func windowedActivityRMS(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        let windowSize = max(1, Int((buffer.format.sampleRate * 0.025).rounded()))
        var bestRMS: Float = 0
        var index = 0

        while index < frameLength {
            let endIndex = min(frameLength, index + windowSize)
            var sumOfSquares: Float = 0
            var sampleCount = 0

            for channel in 0..<channelCount {
                let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameLength)
                for sampleIndex in index..<endIndex {
                    let sample = channelSamples[sampleIndex]
                    sumOfSquares += sample * sample
                    sampleCount += 1
                }
            }

            if sampleCount > 0 {
                let rms = sqrt(sumOfSquares / Float(sampleCount))
                bestRMS = max(bestRMS, rms)
            }

            index += windowSize
        }

        return bestRMS
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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct PCMBufferSnapshot: Sendable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let frameLength: AVAudioFrameCount
    let samples: [Float]

    var duration: TimeInterval {
        Double(frameLength) / max(sampleRate, 1)
    }

    static func make(from buffer: AVAudioPCMBuffer) -> PCMBufferSnapshot? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples: [Float] = []
        samples.reserveCapacity(channelCount * frameLength)

        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameLength)
            samples.append(contentsOf: channelSamples)
        }

        return PCMBufferSnapshot(
            sampleRate: buffer.format.sampleRate,
            channelCount: buffer.format.channelCount,
            frameLength: buffer.frameLength,
            samples: samples
        )
    }

    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        buffer.frameLength = frameLength
        guard let channelData = buffer.floatChannelData else { return nil }

        let framesPerChannel = Int(frameLength)
        for channel in 0..<Int(channelCount) {
            let start = channel * framesPerChannel
            let end = start + framesPerChannel
            samples[start..<end].withUnsafeBufferPointer { src in
                channelData[channel].update(from: src.baseAddress!, count: framesPerChannel)
            }
        }

        return buffer
    }
}
