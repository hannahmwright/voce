@preconcurrency import AVFoundation
import Foundation
import OSLog
import VoceKit

struct OpenAIRealtimeWhisperStopResult: Sendable {
    let rawTranscript: RawTranscript
    let captureURL: URL
}

final class OpenAIRealtimeWhisperCaptureSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "OpenAIRealtimeWhisperCapture")

    private let session: URLSession
    private let authTokenProvider: @Sendable () async throws -> String
    private let model: String
    private let localeIdentifier: String
    private let transcriptionHints: [LexiconEntry]
    private let onPartialText: @Sendable (String) -> Void
    private let onTerminalError: @Sendable (Error) -> Void
    private let onAudioLevel: @Sendable (Double) -> Void
    private let stateLock = NSLock()

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var capturedFrameCount: AVAudioFramePosition = 0
    private var captureStartedAt: ContinuousClock.Instant?
    private var hasStopped = false
    private var latestWriteError: Error?
    private var socket: URLSessionWebSocketTask?
    private var socketWriter: RealtimeWebSocketWriter?
    private var transcriptAccumulator: RealtimeTranscriptAccumulator?
    private var receiveTask: Task<Void, Never>?

    init(
        session: URLSession = .shared,
        authTokenProvider: @escaping @Sendable () async throws -> String,
        model: String = "gpt-realtime-whisper",
        localeIdentifier: String,
        transcriptionHints: [LexiconEntry],
        onPartialText: @escaping @Sendable (String) -> Void,
        onTerminalError: @escaping @Sendable (Error) -> Void = { _ in },
        onAudioLevel: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.session = session
        self.authTokenProvider = authTokenProvider
        self.model = model
        self.localeIdentifier = localeIdentifier
        self.transcriptionHints = Array(transcriptionHints.prefix(200))
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

        let socket = try await makeSocket()
        let writer = RealtimeWebSocketWriter(socket: socket)
        let accumulator = RealtimeTranscriptAccumulator()
        self.socket = socket
        self.socketWriter = writer
        self.transcriptAccumulator = accumulator
        self.outputURL = outputURL
        self.audioFile = audioFile

        socket.resume()
        try await sendSessionUpdate(writer: writer)

        receiveTask = Task { [weak self, socket, accumulator] in
            do {
                try await self?.receiveEvents(from: socket, accumulator: accumulator)
            } catch {
                await accumulator.fail(error)
                self?.recordTerminalError(error)
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

            self.onAudioLevel(Self.normalizedAudioLevel(from: buffer))
            guard let pcmData = Self.convertToRealtimePCMData(buffer), !pcmData.isEmpty else { return }
            Task { [writer] in
                do {
                    try await writer.appendAudio(pcmData)
                } catch {
                    self.recordTerminalError(error)
                }
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            socket.cancel(with: .goingAway, reason: nil)
            receiveTask?.cancel()
            self.audioFile = nil
            self.outputURL = nil
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }

        audioEngine = engine
        stateLock.withLock {
            captureStartedAt = ContinuousClock().now
        }
    }

    func stop() async throws -> OpenAIRealtimeWhisperStopResult {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let stoppedAt = ContinuousClock().now
        let outputURL: URL?
        let wallDurationSeconds: Double?
        (outputURL, wallDurationSeconds) = stateLock.withLock {
            hasStopped = true
            let wallDurationSeconds = captureStartedAt.map { start in
                let duration = start.duration(to: stoppedAt)
                return Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
            }
            let outputURL = self.outputURL
            audioFile = nil
            captureStartedAt = nil
            return (outputURL, wallDurationSeconds)
        }

        if let latestWriteError {
            cleanupOutputFile(at: outputURL)
            throw latestWriteError
        }
        guard let outputURL else {
            throw AppleSpeechPreviewError.missingOutputFile
        }

        guard let writer = socketWriter, let accumulator = transcriptAccumulator else {
            cleanupOutputFile(at: outputURL)
            throw CloudDictationError.invalidResponse
        }

        try await writer.commit()
        let transcript = try await accumulator.waitForFinal(timeoutSeconds: 90)
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()

        let captureDurationMS = Self.captureDurationMS(for: outputURL)
        let wallDurationDescription = wallDurationSeconds.map { "\($0.formatted(.number.precision(.fractionLength(2))))s" } ?? "unknown"
        Self.logger.notice(
            "Realtime capture stopped; wall=\(wallDurationDescription, privacy: .public) file=\(Double(captureDurationMS) / 1_000, format: .fixed(precision: 2))s transcriptChars=\(transcript.count, privacy: .public)"
        )

        return OpenAIRealtimeWhisperStopResult(
            rawTranscript: RawTranscript(
                text: transcript,
                segments: [],
                durationMS: captureDurationMS
            ),
            captureURL: outputURL
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
        socket?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        stateLock.withLock {
            audioFile = nil
            self.outputURL = nil
            latestWriteError = nil
            capturedFrameCount = 0
            captureStartedAt = nil
        }
        cleanupOutputFile(at: outputURL)
    }

    private func makeSocket() async throws -> URLSessionWebSocketTask {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]
        guard let url = components.url else {
            throw CloudDictationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("Bearer \(try await authTokenProvider())", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    private func sendSessionUpdate(writer: RealtimeWebSocketWriter) async throws {
        let transcription: [String: Any] = [
            "model": model,
            "language": Self.effectiveLanguageCode(from: localeIdentifier)
        ]
        try await writer.sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ])
        Self.logger.notice("Realtime transcription session configured with model \(self.model, privacy: .public)")
    }

    private func receiveEvents(
        from socket: URLSessionWebSocketTask,
        accumulator: RealtimeTranscriptAccumulator
    ) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let receivedData):
                data = receivedData
            case .string(let string):
                data = Data(string.utf8)
            @unknown default:
                continue
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }
            if type == "error" {
                let message = ((payload["error"] as? [String: Any])?["message"] as? String)
                    ?? "Realtime transcription failed."
                throw CloudDictationError.providerError(message)
            }
            if type == "conversation.item.input_audio_transcription.delta",
               let delta = payload["delta"] as? String {
                let partial = await accumulator.appendDelta(delta)
                if !partial.isEmpty {
                    onPartialText(partial)
                }
            }
            if type == "conversation.item.input_audio_transcription.completed",
               let transcript = payload["transcript"] as? String {
                let finalText = Self.normalizeText(transcript)
                await accumulator.complete(finalText)
                if !finalText.isEmpty {
                    onPartialText(finalText)
                }
                return
            }
        }
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
            .appendingPathComponent("voce-realtime-whisper-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private static func captureDurationMS(for url: URL) -> Int {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return 0 }
        let durationSeconds = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)
        return Int((durationSeconds * 1_000).rounded())
    }

    private static func effectiveLanguageCode(from localeIdentifier: String) -> String {
        let components = localeIdentifier.split(separator: "-")
        return components.first.map(String.init) ?? "en"
    }

    fileprivate static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convertToRealtimePCMData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let inputProvider = RealtimeCaptureConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
            inputProvider.next(outStatus: outStatus)
        }
        guard conversionError == nil, status != .error else { return nil }
        guard let audioBuffer = targetBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        return Data(bytes: audioBuffer, count: Int(targetBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
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

private final class RealtimeCaptureConverterInputProvider: @unchecked Sendable {
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

private actor RealtimeWebSocketWriter {
    private let socket: URLSessionWebSocketTask

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func appendAudio(_ data: Data) async throws {
        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    func commit() async throws {
        try await sendJSON(["type": "input_audio_buffer.commit"])
    }

    func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CloudDictationError.invalidResponse
        }
        try await socket.send(.string(string))
    }
}

private actor RealtimeTranscriptAccumulator {
    private var partialText = ""
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<Result<String, Error>, Never>?

    func appendDelta(_ delta: String) -> String {
        partialText += delta
        return OpenAIRealtimeWhisperCaptureSession.normalizeText(partialText)
    }

    func complete(_ transcript: String) {
        guard result == nil else { return }
        result = .success(transcript)
        continuation?.resume(returning: .success(transcript))
        continuation = nil
    }

    func fail(_ error: Error) {
        guard result == nil else { return }
        result = .failure(error)
        continuation?.resume(returning: .failure(error))
        continuation = nil
    }

    func waitForFinal(timeoutSeconds: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.waitForResult().get()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CloudDictationError.timedOut
            }
            guard let value = try await group.next() else {
                throw CloudDictationError.timedOut
            }
            group.cancelAll()
            return value
        }
    }

    private func waitForResult() async -> Result<String, Error> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
