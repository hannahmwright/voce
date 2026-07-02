@preconcurrency import AVFoundation
import Foundation
import OSLog
import VoceKit

struct OpenAIRealtimeWhisperStopResult: Sendable {
    let rawTranscript: RawTranscript
    let captureURL: URL
}

struct RealtimePCMConversion {
    let data: Data
    let inputFrameCount: Int
    let outputFrameCount: Int
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
    private var audioSendContinuation: AsyncStream<Data>.Continuation?
    private var audioSendTask: Task<Void, Never>?

    // MARK: Diagnostics
    // This is intentionally narrow realtime instrumentation. It does not
    // change which transcript is returned, but the receive loop stays alive
    // after the first completed event so later server events are visible.
    private var diagSessionID = UUID().uuidString
    private var diagStartAt: ContinuousClock.Instant?
    private var diagFirstBufferLogged = false
    private var diagYieldedChunks = 0
    private var diagYieldedBytes = 0
    private var diagInputFrames = 0
    private var diagOutputFrames = 0
    private var diagAppendedChunks = 0
    private var diagAppendedBytes = 0

    private func diagElapsedMS() -> Int {
        let startAt = stateLock.withLock { diagStartAt }
        guard let startAt else { return -1 }
        let duration = startAt.duration(to: ContinuousClock().now)
        return Int(Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000)
    }

    private static func diagAudioSeconds(fromPCMBytes bytes: Int) -> Double {
        // Int16 mono at 24kHz: 48_000 bytes per second.
        Double(bytes) / 48_000
    }

    private static func diagAudioSeconds(fromOutputFrames frames: Int) -> Double {
        Double(frames) / realtimeTargetFormat.sampleRate
    }

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
            self.diagSessionID = UUID().uuidString
            diagStartAt = ContinuousClock().now
            diagFirstBufferLogged = false
            diagYieldedChunks = 0
            diagYieldedBytes = 0
            diagInputFrames = 0
            diagOutputFrames = 0
            diagAppendedChunks = 0
            diagAppendedBytes = 0
        }
        let diagSessionID = stateLock.withLock { self.diagSessionID }
        Self.logger.notice("RealtimeDiag[\(diagSessionID, privacy: .public)]: start")

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

        // Audio chunks must reach the realtime API strictly in capture order, and
        // every chunk must be on the wire before `commit()` is sent in `stop()`.
        // A single consumer task draining an AsyncStream guarantees both: yields
        // from the tap preserve order, and `stop()` awaits the task after
        // finishing the stream to flush all pending sends. The stream is created
        // before websocket setup so audio captured while the realtime session is
        // arming is buffered locally and sent once the server is ready.
        var sendContinuation: AsyncStream<Data>.Continuation?
        let sendStream = AsyncStream<Data> { sendContinuation = $0 }
        audioSendContinuation = sendContinuation
        self.outputURL = outputURL
        self.audioFile = audioFile

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
            let isFirstBuffer = self.stateLock.withLock { () -> Bool in
                guard !self.diagFirstBufferLogged else { return false }
                self.diagFirstBufferLogged = true
                return true
            }
            if isFirstBuffer {
                Self.logger.notice(
                    "RealtimeDiag: first mic buffer +\(self.diagElapsedMS(), privacy: .public)ms format=\(buffer.format.sampleRate, privacy: .public)Hz ch=\(buffer.format.channelCount, privacy: .public)"
                )
            }
            guard self.stateLock.withLock({ !self.hasStopped }) else { return }
            guard let conversion = Self.convertToRealtimePCMData(buffer),
                  !conversion.data.isEmpty else { return }
            self.stateLock.withLock {
                self.diagYieldedChunks += 1
                self.diagYieldedBytes += conversion.data.count
                self.diagInputFrames += conversion.inputFrameCount
                self.diagOutputFrames += conversion.outputFrameCount
            }
            self.audioSendContinuation?.yield(conversion.data)
        }

        do {
            try engine.start()
        } catch {
            cleanupAfterStartFailure(socket: nil, inputNode: inputNode)
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }

        audioEngine = engine
        stateLock.withLock {
            captureStartedAt = ContinuousClock().now
        }
        Self.logger.notice(
            "RealtimeDiag: engine started +\(self.diagElapsedMS(), privacy: .public)ms input=\(inputFormat.sampleRate, privacy: .public)Hz"
        )

        let socket: URLSessionWebSocketTask
        do {
            socket = try await makeSocket()
        } catch {
            cleanupAfterStartFailure(socket: nil, inputNode: inputNode)
            throw error
        }
        Self.logger.notice("RealtimeDiag: socket created (token fetched) +\(self.diagElapsedMS(), privacy: .public)ms")
        let writer = RealtimeWebSocketWriter(socket: socket)
        let accumulator = RealtimeTranscriptAccumulator()
        let sessionReadiness = RealtimeSessionReadiness()
        self.socket = socket
        self.socketWriter = writer
        self.transcriptAccumulator = accumulator

        socket.resume()
        receiveTask = Task { [weak self, socket, accumulator, sessionReadiness] in
            do {
                try await self?.receiveEvents(
                    from: socket,
                    accumulator: accumulator,
                    sessionReadiness: sessionReadiness
                )
            } catch {
                await sessionReadiness.fail(error)
                await accumulator.fail(error)
                self?.recordTerminalError(error)
            }
        }

        do {
            try await sendSessionUpdate(writer: writer)
            try await sessionReadiness.waitUntilReady(timeoutSeconds: 5)
        } catch {
            cleanupAfterStartFailure(socket: socket, inputNode: inputNode)
            throw error
        }
        Self.logger.notice("RealtimeDiag: session ready, sender starting +\(self.diagElapsedMS(), privacy: .public)ms")
        let (bufferedChunks, bufferedBytes, bufferedOutputFrames) = stateLock.withLock {
            (diagYieldedChunks, diagYieldedBytes, diagOutputFrames)
        }
        Self.logger.notice(
            "RealtimeDiag: buffered before sender chunks=\(bufferedChunks, privacy: .public) bytes=\(bufferedBytes, privacy: .public) outputFrames=\(bufferedOutputFrames, privacy: .public) (~\(Self.diagAudioSeconds(fromOutputFrames: bufferedOutputFrames), format: .fixed(precision: 1))s audio)"
        )

        audioSendTask = Task { [weak self, writer] in
            var isFirstAppend = true
            for await pcmData in sendStream {
                do {
                    try await writer.appendAudio(pcmData)
                    if let self {
                        let (chunks, bytes) = self.stateLock.withLock { () -> (Int, Int) in
                            self.diagAppendedChunks += 1
                            self.diagAppendedBytes += pcmData.count
                            return (self.diagAppendedChunks, self.diagAppendedBytes)
                        }
                        if isFirstAppend {
                            isFirstAppend = false
                            Self.logger.notice(
                                "RealtimeDiag: first audio append +\(self.diagElapsedMS(), privacy: .public)ms bytes=\(pcmData.count, privacy: .public)"
                            )
                        }
                        _ = (chunks, bytes)
                    }
                } catch {
                    self?.recordTerminalError(error)
                    break
                }
            }
            if let self {
                let (chunks, bytes) = self.stateLock.withLock { (self.diagAppendedChunks, self.diagAppendedBytes) }
                Self.logger.notice(
                    "RealtimeDiag: sender finished +\(self.diagElapsedMS(), privacy: .public)ms appendedChunks=\(chunks, privacy: .public) appendedBytes=\(bytes, privacy: .public) (~\(Self.diagAudioSeconds(fromPCMBytes: bytes), format: .fixed(precision: 1))s by bytes)"
                )
            }
        }
    }

    func stop() async throws -> OpenAIRealtimeWhisperStopResult {
        Self.logger.notice("RealtimeDiag: stop initiated +\(self.diagElapsedMS(), privacy: .public)ms")
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

        // Wait for every queued audio chunk to hit the wire before committing.
        // Committing early makes the API transcribe only the audio it has
        // received so far, cutting off the end of the dictation.
        stateLock.withLock {
            audioSendContinuation?.finish()
            audioSendContinuation = nil
        }
        // Bound the drain so a wedged websocket send can never hang `stop()`
        // forever. On timeout we must NOT attempt `commit()`: it goes through
        // the same writer/socket and can block behind the stuck send
        // (`waitForFinal`'s 90s cap only starts after commit returns).
        // Instead, tear the connection down and fail fast.
        if let audioSendTask {
            self.audioSendTask = nil
            do {
                try await Self.ensureDrained(audioSendTask, timeoutSeconds: 10)
            } catch {
                Self.logger.error("Timed out draining realtime audio sends; abandoning wedged connection without commit")
                abandonWedgedRealtimeConnection()
                cleanupOutputFile(at: outputURL)
                throw error
            }
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

        let (sentChunks, sentBytes, inputFrames, outputFrames, capturedFrames) = stateLock.withLock {
            (diagAppendedChunks, diagAppendedBytes, diagInputFrames, diagOutputFrames, capturedFrameCount)
        }
        Self.logger.notice(
            "RealtimeDiag: drained, committing +\(self.diagElapsedMS(), privacy: .public)ms appendedChunks=\(sentChunks, privacy: .public) appendedBytes=\(sentBytes, privacy: .public) capturedFrames=\(capturedFrames, privacy: .public) inputFrames=\(inputFrames, privacy: .public) outputFrames=\(outputFrames, privacy: .public) (~\(Self.diagAudioSeconds(fromOutputFrames: outputFrames), format: .fixed(precision: 1))s audio on wire)"
        )
        try await writer.commit()
        Self.logger.notice("RealtimeDiag: commit sent +\(self.diagElapsedMS(), privacy: .public)ms")
        let transcript = try await accumulator.waitForFinal(timeoutSeconds: 90)
        Self.logger.notice(
            "RealtimeDiag: final transcript received +\(self.diagElapsedMS(), privacy: .public)ms chars=\(transcript.count, privacy: .public) preview=\"\(Self.diagPreview(transcript), privacy: .public)\""
        )
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
        audioSendTask?.cancel()
        audioSendTask = nil
        stateLock.withLock {
            audioSendContinuation?.finish()
            audioSendContinuation = nil
            audioFile = nil
            self.outputURL = nil
            latestWriteError = nil
            capturedFrameCount = 0
            captureStartedAt = nil
        }
        cleanupOutputFile(at: outputURL)
    }

    /// Gate between draining audio sends and committing the buffer: throws on
    /// timeout (after cancelling the sender) so the caller fails fast instead
    /// of issuing `commit()` over a websocket that may be wedged mid-send.
    static func ensureDrained(_ sendTask: Task<Void, Never>, timeoutSeconds: TimeInterval) async throws {
        guard await wait(for: sendTask, timeoutSeconds: timeoutSeconds) else {
            sendTask.cancel()
            throw CloudDictationError.timedOut
        }
    }

    /// Tears down the realtime connection after a drain timeout. The socket
    /// cancel also unblocks the leftover sender task: its in-flight
    /// `URLSessionWebSocketTask.send` fails once the socket dies.
    private func abandonWedgedRealtimeConnection() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        socketWriter = nil
        transcriptAccumulator = nil
    }

    /// Waits for `task` to finish, returning `false` if it does not within the
    /// timeout. Deliberately avoids a task group: a group scope cannot return
    /// until all children finish, and awaiting `task.value` is not
    /// interruptible by cancellation, so a group-based race would still hang
    /// on a wedged send. Here the loser is an unstructured task that resumes
    /// a one-shot continuation as a no-op, so the caller is never blocked. If
    /// the timeout wins, the leftover waiter task ends once the websocket is
    /// torn down and the pending send fails.
    static func wait(for task: Task<Void, Never>, timeoutSeconds: TimeInterval) async -> Bool {
        let once = OneShotContinuation()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task {
                await task.value
                once.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                once.resume(false)
            }
        }
    }

    private func cleanupAfterStartFailure(socket: URLSessionWebSocketTask?, inputNode: AVAudioInputNode?) {
        inputNode?.removeTap(onBus: 0)
        socket?.cancel(with: .goingAway, reason: nil)
        audioEngine?.stop()
        audioEngine = nil
        receiveTask?.cancel()
        receiveTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        self.socket = nil
        socketWriter = nil
        transcriptAccumulator = nil
        let staleOutputURL = stateLock.withLock { () -> URL? in
            audioSendContinuation?.finish()
            audioSendContinuation = nil
            audioFile = nil
            let url = outputURL
            outputURL = nil
            return url
        }
        cleanupOutputFile(at: staleOutputURL)
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
        accumulator: RealtimeTranscriptAccumulator,
        sessionReadiness: RealtimeSessionReadiness
    ) async throws {
        var eventCounts: [String: Int] = [:]
        var firstDeltaLogged = false
        var completedCount = 0
        var firstCompletedDelivered = false
        defer {
            let summary = eventCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            Self.logger.notice(
                "RealtimeDiag: receive loop ended +\(self.diagElapsedMS(), privacy: .public)ms events: \(summary, privacy: .public)"
            )
        }
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
            eventCounts[type, default: 0] += 1
            // Buffer/turn lifecycle events reveal whether the server is
            // segmenting our audio (VAD active despite turn_detection: null)
            // or truncating the input buffer.
            let itemID = Self.realtimeItemID(from: payload)
            if type.hasPrefix("input_audio_buffer.") || type == "conversation.item.created" {
                Self.logger.notice(
                    "RealtimeDiag: event \(type, privacy: .public) #\(eventCounts[type] ?? 0, privacy: .public) item=\(itemID, privacy: .public) +\(self.diagElapsedMS(), privacy: .public)ms"
                )
            }
            if type == "error" {
                let message = ((payload["error"] as? [String: Any])?["message"] as? String)
                    ?? "Realtime transcription failed."
                Self.logger.error("RealtimeDiag: server error event +\(self.diagElapsedMS(), privacy: .public)ms message=\(message, privacy: .public)")
                throw CloudDictationError.providerError(message)
            }
            if type == "session.updated" || type == "transcription_session.updated" {
                await sessionReadiness.markReady()
            }
            if type == "conversation.item.input_audio_transcription.delta",
               let delta = payload["delta"] as? String {
                let deltaCount = eventCounts[type] ?? 0
                if !firstDeltaLogged {
                    firstDeltaLogged = true
                    Self.logger.notice("RealtimeDiag: first transcript delta +\(self.diagElapsedMS(), privacy: .public)ms")
                }
                let partial = await accumulator.appendDelta(delta)
                if deltaCount <= 12 || deltaCount.isMultiple(of: 50) {
                    Self.logger.notice(
                        "RealtimeDiag: delta #\(deltaCount, privacy: .public) item=\(itemID, privacy: .public) deltaChars=\(delta.count, privacy: .public) partialChars=\(partial.count, privacy: .public) delta=\"\(Self.diagPreview(delta), privacy: .public)\""
                    )
                }
                if !partial.isEmpty {
                    onPartialText(partial)
                }
            }
            if type == "conversation.item.input_audio_transcription.completed",
               let transcript = payload["transcript"] as? String {
                completedCount += 1
                Self.logger.notice(
                    "RealtimeDiag: completed event #\(completedCount, privacy: .public) item=\(itemID, privacy: .public) chars=\(transcript.count, privacy: .public) +\(self.diagElapsedMS(), privacy: .public)ms preview=\"\(Self.diagPreview(transcript), privacy: .public)\""
                )
                if !firstCompletedDelivered {
                    firstCompletedDelivered = true
                    let finalText = Self.normalizeText(transcript)
                    await accumulator.complete(finalText)
                    if !finalText.isEmpty {
                        onPartialText(finalText)
                    }
                    Self.logger.notice(
                        "RealtimeDiag: completed event #\(completedCount, privacy: .public) delivered to accumulator; continuing receive loop for diagnostics"
                    )
                } else {
                    Self.logger.notice(
                        "RealtimeDiag: completed event #\(completedCount, privacy: .public) observed after accumulator already completed"
                    )
                }
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

    private static func realtimeItemID(from payload: [String: Any]) -> String {
        if let itemID = payload["item_id"] as? String {
            return itemID
        }
        if let item = payload["item"] as? [String: Any],
           let itemID = item["id"] as? String {
            return itemID
        }
        return "-"
    }

    private static func diagPreview(_ text: String, limit: Int = 96) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "..."
    }

    static var realtimeTargetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }

    static func convertToRealtimePCMData(_ buffer: AVAudioPCMBuffer) -> RealtimePCMConversion? {
        let targetFormat = realtimeTargetFormat
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }
        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = max(1_024, AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024)
        let inputProvider = RealtimeCaptureConverterInputProvider(buffer: buffer)
        var data = Data()
        var outputFrameCount = 0

        while true {
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return nil
            }
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                inputProvider.next(outStatus: outStatus)
            }
            guard conversionError == nil, status != .error else { return nil }
            if targetBuffer.frameLength > 0,
               let chunk = pcmData(from: targetBuffer) {
                data.append(chunk)
                outputFrameCount += Int(targetBuffer.frameLength)
            }
            if status == .endOfStream || status == .inputRanDry {
                break
            }
            if status == .haveData, targetBuffer.frameLength == 0 {
                break
            }
        }

        guard !data.isEmpty else { return nil }
        return RealtimePCMConversion(
            data: data,
            inputFrameCount: Int(buffer.frameLength),
            outputFrameCount: outputFrameCount
        )
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let audioBuffer = buffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        return Data(bytes: audioBuffer, count: Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
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

private final class OneShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private actor RealtimeSessionReadiness {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    func markReady() {
        complete(.success(()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    func waitUntilReady(timeoutSeconds: TimeInterval) async throws {
        let once = OneShotReadinessContinuation()
        let result = await withCheckedContinuation { continuation in
            once.set(continuation)
            Task {
                let result = await self.waitForResult()
                once.resume(result)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                let timeout = CloudDictationError.timedOut
                self.fail(timeout)
                once.resume(.failure(timeout))
            }
        }
        try result.get()
    }

    private func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func waitForResult() async -> Result<Void, Error> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private final class OneShotReadinessContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    func set(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<Void, Error>, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private final class RealtimeCaptureConverterInputProvider: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private var didEndStream = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didEndStream {
            outStatus.pointee = .endOfStream
            return nil
        }
        guard let buffer else {
            didEndStream = true
            outStatus.pointee = .endOfStream
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
        let once = OneShotTranscriptContinuation()
        let result = await withCheckedContinuation { continuation in
            once.set(continuation)
            Task {
                let result = await self.waitForResult()
                once.resume(result)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                let timeout = CloudDictationError.timedOut
                self.fail(timeout)
                once.resume(.failure(timeout))
            }
        }
        return try result.get()
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

private final class OneShotTranscriptContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<String, Error>, Never>?

    func set(_ continuation: CheckedContinuation<Result<String, Error>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Result<String, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<String, Error>, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
