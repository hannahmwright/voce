@preconcurrency import AVFoundation
import Foundation
import OSLog
import VoceKit

struct OpenAIRealtimeWhisperStopResult: Sendable {
    let rawTranscript: RawTranscript
}

struct RealtimePCMConversion {
    let data: Data
    let inputFrameCount: Int
    let outputFrameCount: Int
}

enum RealtimeDictationRecoveryError: Error, LocalizedError {
    case unableToCreateCheckpoint

    var errorDescription: String? {
        switch self {
        case .unableToCreateCheckpoint:
            return "Voce could not create a recovery checkpoint for this dictation."
        }
    }
}

/// A durable transcript checkpoint for an active realtime dictation. The
/// capture session rewrites it with the combined long-form transcript as
/// text arrives (throttled), so a socket failure or app termination cannot
/// erase everything the provider has already transcribed.
final class RealtimeDictationRecoveryCheckpoint: @unchecked Sendable {
    struct PendingRecovery: Sendable {
        let url: URL
        let text: String
        let modifiedAt: Date
    }

    private let lock = NSLock()
    private let url: URL
    private var handle: FileHandle?
    private var text = ""
    private var lastSynchronizationAt = Date.distantPast
    private var lastRevision: UInt64 = 0

    init(
        directoryURL: URL = RealtimeDictationRecoveryCheckpoint.defaultDirectoryURL()
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let url = directoryURL
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw RealtimeDictationRecoveryError.unableToCreateCheckpoint
            }
            self.url = url
            self.handle = try FileHandle(forWritingTo: url)
        } catch let error as RealtimeDictationRecoveryError {
            throw error
        } catch {
            throw RealtimeDictationRecoveryError.unableToCreateCheckpoint
        }
    }

    func append(delta: String) {
        guard !delta.isEmpty else { return }
        lock.withLock {
            text += delta
            guard let data = delta.data(using: .utf8), let handle else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                let now = Date()
                if now.timeIntervalSince(lastSynchronizationAt) >= 1 {
                    try handle.synchronize()
                    lastSynchronizationAt = now
                }
            } catch {
                // The in-memory snapshot remains available to the immediate
                // failure handler even if the durable flush fails.
            }
        }
    }

    /// Replaces the checkpoint with a full transcript. When `revision` is
    /// given, an older render never overwrites a newer one, so concurrent
    /// writers (throttled partials, segment completion) cannot regress it.
    /// The new text is written before the file is truncated so an
    /// interrupted write never leaves an empty checkpoint. Without
    /// `synchronize`, the flush to disk is throttled to once a second.
    func replace(with transcript: String, revision: UInt64? = nil, synchronize: Bool = true) {
        lock.withLock {
            if let revision {
                guard revision >= lastRevision else { return }
                lastRevision = revision
            }
            text = transcript
            guard let data = transcript.data(using: .utf8), let handle else { return }
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: data)
                try handle.truncate(atOffset: UInt64(data.count))
                let now = Date()
                if synchronize || now.timeIntervalSince(lastSynchronizationAt) >= 1 {
                    try handle.synchronize()
                    lastSynchronizationAt = now
                }
            } catch {
                // Keep the in-memory transcript available for recovery.
            }
        }
    }

    func snapshot() -> String {
        lock.withLock { text }
    }

    func discard() {
        let checkpointURL = lock.withLock { () -> URL in
            try? handle?.close()
            handle = nil
            return url
        }
        try? FileManager.default.removeItem(at: checkpointURL)
    }

    func preserveForNextLaunch() {
        lock.withLock {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    static func pendingRecoveries(
        directoryURL: URL = defaultDirectoryURL()
    ) -> [PendingRecovery] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "txt",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return PendingRecovery(
                url: url,
                text: text,
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.modifiedAt < $1.modifiedAt }
    }

    static func discardPending(_ recoveries: [PendingRecovery]) {
        for recovery in recoveries {
            try? FileManager.default.removeItem(at: recovery.url)
        }
    }

    static func defaultDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.voceapp.voce"
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Dictation Recovery", isDirectory: true)
    }

    deinit {
        try? handle?.close()
    }
}

final class OpenAIRealtimeWhisperCaptureSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "OpenAIRealtimeWhisperCapture")
    /// OpenAI currently caps one Realtime session at 60 minutes. Rollover at
    /// 50 minutes leaves enough time to fetch a new credential and retry the
    /// handshake without approaching the provider-enforced disconnect.
    static let connectionRolloverIntervalSeconds: TimeInterval = 50 * 60
    /// Mic buffers arrive roughly every 21 ms. Coalescing them into ~100 ms
    /// appends (24 kHz mono Int16) cuts websocket messages, JSON encoding and
    /// base64 work about fivefold while adding at most ~100 ms of latency.
    static let audioAppendBatchBytes = 4_800
    /// Upper bound for the websocket handshake, `session.update` and its
    /// acknowledgement together. Mic audio captured meanwhile is buffered,
    /// so this also bounds the local backlog while arming.
    static let connectionHandshakeTimeoutSeconds: TimeInterval = 10

    private let session: URLSession
    private let authTokenProvider: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let model: String
    private let localeIdentifier: String
    private let transcriptionHints: [LexiconEntry]
    private let onPartialText: @Sendable (String) -> Void
    private let onTerminalError: @Sendable (Error) -> Void
    private let onAudioLevel: @Sendable (Double) -> Void
    /// Guards every mutable property below. Callers arrive from the main
    /// actor (`cancel()`), the audio tap thread, URLSession callbacks and
    /// background tasks (`stop()`, rollover), so never read or write them
    /// without it, and never hold it across an `await`.
    private let stateLock = NSLock()
    /// Serializes engine lifecycle work (start, restart after an input device
    /// change, teardown). Lock order: `engineLock` before `stateLock`. The
    /// audio tap never takes it, so `removeTap` cannot deadlock against an
    /// in-flight buffer.
    private let engineLock = NSLock()
    private let engineConfigurationQueue = DispatchQueue(
        label: "io.voceapp.voce.realtime-capture.engine-configuration"
    )

    private var audioEngine: AVAudioEngine?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var capturedFrameCount: AVAudioFramePosition = 0
    /// Captured audio duration, accumulated per buffer so it stays correct
    /// even if the input sample rate changes mid-dictation. Raw audio is not
    /// written to disk: only its duration is needed for usage metering.
    private var capturedDurationSeconds: Double = 0
    private var captureStartedAt: ContinuousClock.Instant?
    private var lastAudibleAt: ContinuousClock.Instant?
    private var hasStopped = false
    private var latestWriteError: Error?
    /// The connection currently receiving audio.
    private var connection: RealtimeConnection?
    /// The previous connection while a rollover finalizes it, tracked so
    /// `cancel()` and failure paths close it too.
    private var retiringConnection: RealtimeConnection?
    private var audioSendContinuation: AsyncStream<Data>.Continuation?
    /// Converted PCM waiting to reach `audioAppendBatchBytes` before it is
    /// yielded to the sender. Flushed by `stop()` ahead of the commit.
    private var pendingAudio = Data()
    private let pcmConverter = CachedPCMConverter(
        outputFormat: OpenAIRealtimeWhisperCaptureSession.realtimeTargetFormat
    )
    private var audioSendTask: Task<Void, Never>?
    private var audioRouter: RealtimeAudioRouter?
    private var rolloverTask: Task<Void, Never>?
    private let longFormTranscript = RealtimeLongFormTranscript()
    private var recoveryCheckpoint: RealtimeDictationRecoveryCheckpoint?
    /// Coalesces transcript updates: at most ~10 partial-text callbacks and
    /// checkpoint rewrites per second, always including the latest text.
    private var partialTranscriptThrottle: CoalescingThrottle?

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
        authTokenProvider: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        model: String = OpenAIRealtimeTranscriptionConfiguration.defaultModel,
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
        await longFormTranscript.reset()
        stateLock.withLock {
            hasStopped = false
            latestWriteError = nil
            capturedFrameCount = 0
            capturedDurationSeconds = 0
            captureStartedAt = nil
            lastAudibleAt = nil
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
        let recoveryCheckpoint = try RealtimeDictationRecoveryCheckpoint()
        let partialTranscriptThrottle = CoalescingThrottle(interval: 0.1) { [weak self] in
            await self?.publishPartialTranscript()
        }
        stateLock.withLock {
            self.recoveryCheckpoint = recoveryCheckpoint
            self.partialTranscriptThrottle?.invalidate()
            self.partialTranscriptThrottle = partialTranscriptThrottle
        }

        // Audio chunks must reach the realtime API strictly in capture order, and
        // every chunk must be on the wire before `commit()` is sent in `stop()`.
        // A single consumer task draining an AsyncStream guarantees both: yields
        // from the tap preserve order, and `stop()` awaits the task after
        // finishing the stream to flush all pending sends. The stream is created
        // before websocket setup so audio captured while the realtime session is
        // arming is buffered locally and sent once the server is ready.
        let (sendStream, sendContinuation) = AsyncStream<Data>.makeStream()
        stateLock.withLock {
            audioSendContinuation = sendContinuation
            pendingAudio = Data()
        }

        let inputFormat: AVAudioFormat
        do {
            inputFormat = try engineLock.withLock { () throws -> AVAudioFormat in
                let inputFormat = try installCaptureTap(on: engine)
                do {
                    try engine.start()
                } catch {
                    engine.inputNode.removeTap(onBus: 0)
                    throw error
                }
                // When the input device changes (AirPods connect, a USB mic is
                // unplugged) the engine stops itself and posts this; without
                // handling it audio silently ends mid-dictation.
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
                    lastAudibleAt = captureStartedAt
                    return true
                }
                guard installed else {
                    NotificationCenter.default.removeObserver(observer)
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    throw CancellationError()
                }
                return inputFormat
            }
        } catch is CancellationError {
            cleanupAfterStartFailure()
            throw CancellationError()
        } catch {
            cleanupAfterStartFailure()
            throw AppleSpeechPreviewError.failedToStartAudioEngine
        }
        Self.logger.notice(
            "RealtimeDiag: engine started +\(self.diagElapsedMS(), privacy: .public)ms input=\(inputFormat.sampleRate, privacy: .public)Hz"
        )

        let connection: RealtimeConnection
        do {
            connection = try await openConnection(forceCredentialRefresh: false)
        } catch {
            cleanupAfterStartFailure()
            throw error
        }
        Self.logger.notice("RealtimeDiag: socket created (token fetched) +\(self.diagElapsedMS(), privacy: .public)ms")
        let audioRouter = RealtimeAudioRouter(writer: connection.writer)
        // Install the connection and its sender together so `stop()` or
        // `cancel()` always sees either neither or both, and a cancel that
        // landed while arming tears the new socket down instead of leaking it.
        let connectionInstalled = stateLock.withLock { () -> Bool in
            guard !hasStopped else { return false }
            self.connection = connection
            self.audioRouter = audioRouter
            self.audioSendTask = makeAudioSendTask(stream: sendStream, router: audioRouter)
            return true
        }
        guard connectionInstalled else {
            await discard(connection)
            cleanupAfterStartFailure()
            throw CancellationError()
        }
        Self.logger.notice("RealtimeDiag: session ready, sender starting +\(self.diagElapsedMS(), privacy: .public)ms")
        let (bufferedChunks, bufferedBytes, bufferedOutputFrames) = stateLock.withLock {
            (diagYieldedChunks, diagYieldedBytes, diagOutputFrames)
        }
        Self.logger.notice(
            "RealtimeDiag: buffered before sender chunks=\(bufferedChunks, privacy: .public) bytes=\(bufferedBytes, privacy: .public) outputFrames=\(bufferedOutputFrames, privacy: .public) (~\(Self.diagAudioSeconds(fromOutputFrames: bufferedOutputFrames), format: .fixed(precision: 1))s audio)"
        )
        scheduleConnectionRollover()
    }

    /// Runs on the audio tap thread. Never call `diagElapsedMS()` (or anything
    /// else that takes `stateLock`) while holding the lock here.
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.withLock {
            guard !hasStopped else { return }
            capturedFrameCount += AVAudioFramePosition(buffer.frameLength)
            capturedDurationSeconds += Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        }

        let audioLevel = Self.normalizedAudioLevel(from: buffer)
        onAudioLevel(audioLevel)
        if audioLevel >= 0.08 {
            stateLock.withLock {
                lastAudibleAt = ContinuousClock().now
            }
        }
        let isFirstBuffer = stateLock.withLock { () -> Bool in
            guard !diagFirstBufferLogged else { return false }
            diagFirstBufferLogged = true
            return true
        }
        if isFirstBuffer {
            Self.logger.notice(
                "RealtimeDiag: first mic buffer +\(self.diagElapsedMS(), privacy: .public)ms format=\(buffer.format.sampleRate, privacy: .public)Hz ch=\(buffer.format.channelCount, privacy: .public)"
            )
        }
        guard stateLock.withLock({ !hasStopped }) else { return }
        guard let conversion = Self.convertToRealtimePCMData(buffer, using: pcmConverter),
              !conversion.data.isEmpty else { return }
        stateLock.withLock {
            // Yield under the lock so batches stay in capture order and
            // `stop()` can flush the remainder before finishing the stream.
            guard !hasStopped else { return }
            diagInputFrames += conversion.inputFrameCount
            diagOutputFrames += conversion.outputFrameCount
            pendingAudio.append(conversion.data)
            guard pendingAudio.count >= Self.audioAppendBatchBytes else { return }
            diagYieldedChunks += 1
            diagYieldedBytes += pendingAudio.count
            audioSendContinuation?.yield(pendingAudio)
            pendingAudio = Data()
        }
    }

    private func makeAudioSendTask(
        stream sendStream: AsyncStream<Data>,
        router audioRouter: RealtimeAudioRouter
    ) -> Task<Void, Never> {
        Task { [weak self, audioRouter] in
            var isFirstAppend = true
            for await pcmData in sendStream {
                do {
                    try await audioRouter.appendAudio(pcmData)
                    if let self {
                        self.stateLock.withLock {
                            self.diagAppendedChunks += 1
                            self.diagAppendedBytes += pcmData.count
                        }
                        if isFirstAppend {
                            isFirstAppend = false
                            Self.logger.notice(
                                "RealtimeDiag: first audio append +\(self.diagElapsedMS(), privacy: .public)ms bytes=\(pcmData.count, privacy: .public)"
                            )
                        }
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
        stopAudioEngine()

        let stoppedAt = ContinuousClock().now
        let (pendingRollover, audioSendTask, capturedDurationSeconds, wallDurationSeconds) = stateLock.withLock {
            hasStopped = true
            let pendingRollover = rolloverTask
            rolloverTask = nil
            let wallDurationSeconds = captureStartedAt.map { start in
                let duration = start.duration(to: stoppedAt)
                return Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
            }
            captureStartedAt = nil
            lastAudibleAt = nil

            // Wait for every queued audio chunk to hit the wire before
            // committing. Committing early makes the API transcribe only the
            // audio it has received so far, cutting off the end of the
            // dictation. Flush the partial batch, then end the stream so the
            // sender drains everything.
            if !pendingAudio.isEmpty {
                diagYieldedChunks += 1
                diagYieldedBytes += pendingAudio.count
                audioSendContinuation?.yield(pendingAudio)
            }
            pendingAudio = Data()
            audioSendContinuation?.finish()
            audioSendContinuation = nil
            let audioSendTask = self.audioSendTask
            self.audioSendTask = nil
            return (pendingRollover, audioSendTask, self.capturedDurationSeconds, wallDurationSeconds)
        }
        pendingRollover?.cancel()

        // Bound the drain so a wedged websocket send can never hang `stop()`
        // forever. On timeout we must NOT attempt `commit()`: it goes through
        // the same writer/socket and can block behind the stuck send
        // (`waitForFinal`'s 90s cap only starts after commit returns).
        // Instead, tear the connection down and fail fast.
        if let audioSendTask {
            do {
                try await Self.ensureDrained(audioSendTask, timeoutSeconds: 10)
            } catch {
                Self.logger.error("Timed out draining realtime audio sends; abandoning wedged connection without commit")
                abandonRealtimeConnection()
                await persistRecoveryCheckpoint()
                throw error
            }
        }
        // If a rollover was already between handshakes, let that atomic swap
        // settle before selecting the connection that receives the final commit.
        await pendingRollover?.value

        if let latestWriteError = stateLock.withLock({ latestWriteError }) {
            abandonRealtimeConnection()
            await persistRecoveryCheckpoint()
            throw latestWriteError
        }

        guard let connection = stateLock.withLock({ self.connection }) else {
            abandonRealtimeConnection()
            await persistRecoveryCheckpoint()
            throw CloudDictationError.invalidResponse
        }

        let (sentChunks, sentBytes, inputFrames, outputFrames, capturedFrames) = stateLock.withLock {
            (diagAppendedChunks, diagAppendedBytes, diagInputFrames, diagOutputFrames, capturedFrameCount)
        }
        Self.logger.notice(
            "RealtimeDiag: drained, committing +\(self.diagElapsedMS(), privacy: .public)ms appendedChunks=\(sentChunks, privacy: .public) appendedBytes=\(sentBytes, privacy: .public) capturedFrames=\(capturedFrames, privacy: .public) inputFrames=\(inputFrames, privacy: .public) outputFrames=\(outputFrames, privacy: .public) (~\(Self.diagAudioSeconds(fromOutputFrames: outputFrames), format: .fixed(precision: 1))s audio on wire)"
        )
        let activeSegmentTranscript: String
        do {
            try await connection.writer.commit()
            Self.logger.notice("RealtimeDiag: commit sent +\(self.diagElapsedMS(), privacy: .public)ms")
            activeSegmentTranscript = try await connection.accumulator.waitForFinal(timeoutSeconds: 90)
        } catch {
            // Without this the receive loop keeps the session and its socket
            // alive until the server closes the connection. The recovery
            // checkpoint is separate, so clipboard recovery still works.
            abandonRealtimeConnection()
            await persistRecoveryCheckpoint()
            throw error
        }
        _ = await longFormTranscript.completeSegment(
            connection.segmentID,
            transcript: activeSegmentTranscript
        )
        let transcript = await persistRecoveryCheckpoint()
        stateLock.withLock { partialTranscriptThrottle }?.invalidate()
        Self.logger.notice(
            "RealtimeDiag: final transcript received +\(self.diagElapsedMS(), privacy: .public)ms chars=\(transcript.count, privacy: .public)"
        )
        closeConnections(closeCode: .normalClosure)

        let captureDurationMS = Int((capturedDurationSeconds * 1_000).rounded())
        let wallDurationDescription = wallDurationSeconds.map { "\($0.formatted(.number.precision(.fractionLength(2))))s" } ?? "unknown"
        Self.logger.notice(
            "Realtime capture stopped; wall=\(wallDurationDescription, privacy: .public) captured=\(capturedDurationSeconds, format: .fixed(precision: 2))s transcriptChars=\(transcript.count, privacy: .public)"
        )

        return OpenAIRealtimeWhisperStopResult(
            rawTranscript: RawTranscript(
                text: transcript,
                segments: [],
                durationMS: captureDurationMS
            )
        )
    }

    func cancel() {
        stopAudioEngine()
        let (rolloverTask, audioSendTask) = stateLock.withLock {
            hasStopped = true
            let rolloverTask = self.rolloverTask
            self.rolloverTask = nil
            let audioSendTask = self.audioSendTask
            self.audioSendTask = nil
            audioSendContinuation?.finish()
            audioSendContinuation = nil
            pendingAudio = Data()
            latestWriteError = nil
            capturedFrameCount = 0
            capturedDurationSeconds = 0
            captureStartedAt = nil
            lastAudibleAt = nil
            partialTranscriptThrottle?.invalidate()
            return (rolloverTask, audioSendTask)
        }
        // A rollover in flight notices `hasStopped` after its next await and
        // discards any replacement it opened; the connections it may already
        // hold (active and retiring) are closed here.
        rolloverTask?.cancel()
        audioSendTask?.cancel()
        abandonRealtimeConnection()
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

    /// Tears down the realtime connections when `stop()` fails, e.g. after a
    /// drain timeout. The socket cancel also unblocks a leftover sender task:
    /// its in-flight `URLSessionWebSocketTask.send` fails once the socket dies.
    private func abandonRealtimeConnection() {
        closeConnections(closeCode: .goingAway)
    }

    /// Detaches the active and retiring connections under the lock, then
    /// closes them outside it.
    private func closeConnections(closeCode: URLSessionWebSocketTask.CloseCode) {
        let (active, retiring) = stateLock.withLock {
            defer {
                connection = nil
                retiringConnection = nil
                audioRouter = nil
            }
            return (connection, retiringConnection)
        }
        for connection in [active, retiring].compactMap({ $0 }) {
            connection.receiveTask.cancel()
            connection.socket.cancel(with: closeCode, reason: nil)
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

    /// Installs the capture tap using the input node's current format.
    /// Must be called with `engineLock` held.
    private func installCaptureTap(on engine: AVAudioEngine) throws -> AVAudioFormat {
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
        return inputFormat
    }

    /// Restarts capture with the new input format after the engine stopped
    /// itself for a configuration change. Per-buffer conversion already
    /// adapts to a new format. If the input stays unusable, ends the
    /// dictation through `onTerminalError` so the controller recovers the
    /// transcript instead of silently returning a truncated one.
    private func handleEngineConfigurationChange(attempt: Int) {
        let maximumAttempts = 3
        let result = engineLock.withLock { () -> Result<AVAudioFormat, Error>? in
            guard let engine = stateLock.withLock({ hasStopped ? nil : audioEngine }) else {
                return nil
            }
            engine.inputNode.removeTap(onBus: 0)
            do {
                let inputFormat = try installCaptureTap(on: engine)
                engine.prepare()
                try engine.start()
                return .success(inputFormat)
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                return .failure(error)
            }
        }
        switch result {
        case .none:
            return
        case .success(let inputFormat):
            Self.logger.notice(
                "Realtime capture restarted after audio configuration change; input=\(inputFormat.sampleRate, privacy: .public)Hz ch=\(inputFormat.channelCount, privacy: .public)"
            )
        case .failure(let error):
            Self.logger.error(
                "Realtime capture restart attempt \(attempt, privacy: .public) after audio configuration change failed: \(error.localizedDescription, privacy: .public)"
            )
            // The new device can briefly report no format while it settles.
            if attempt < maximumAttempts {
                engineConfigurationQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.handleEngineConfigurationChange(attempt: attempt + 1)
                }
            } else {
                recordTerminalError(AppleSpeechPreviewError.audioInputUnavailable)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.withLock { hasStopped }
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

    private func cleanupAfterStartFailure() {
        stopAudioEngine()
        let (rolloverTask, audioSendTask) = stateLock.withLock {
            hasStopped = true
            let rolloverTask = self.rolloverTask
            self.rolloverTask = nil
            let audioSendTask = self.audioSendTask
            self.audioSendTask = nil
            audioSendContinuation?.finish()
            audioSendContinuation = nil
            pendingAudio = Data()
            partialTranscriptThrottle?.invalidate()
            return (rolloverTask, audioSendTask)
        }
        rolloverTask?.cancel()
        audioSendTask?.cancel()
        abandonRealtimeConnection()
        discardRecoveryCheckpoint()
    }

    private struct RealtimeConnection {
        let segmentID: UUID
        let socket: URLSessionWebSocketTask
        let writer: RealtimeWebSocketWriter
        let accumulator: RealtimeTranscriptAccumulator
        let receiveTask: Task<Void, Never>

        /// The accumulator fails as soon as the receive loop errors, so an
        /// open accumulator plus a running socket means the server has not
        /// closed the session.
        func isHealthy() async -> Bool {
            guard socket.state == .running, socket.closeCode == .invalid else { return false }
            return await accumulator.isOpen
        }
    }

    /// Credential, entitlement and quota failures will not recover within the
    /// rollover window, so they end the dictation right away (its transcript
    /// is still recovered) instead of being retried for three minutes.
    static func isNonRetryableConnectionError(_ error: Error) -> Bool {
        switch error as? CloudDictationError {
        case .missingAPIKey,
             .authenticationRequired,
             .authenticationFailed,
             .subscriptionRequired,
             .hostedCloudMinutesExhausted:
            return true
        case .providerError(let message):
            let lowercased = message.lowercased()
            return CloudDictationError.isQuotaExhaustedMessage(message)
                || lowercased.contains("invalid_api_key")
                || lowercased.contains("incorrect api key")
        default:
            return false
        }
    }

    /// A rejected websocket upgrade surfaces as a generic URL error; report
    /// 401/403 as an authentication failure so it is not retried.
    private static func connectionError(for socket: URLSessionWebSocketTask, underlying error: Error) -> Error {
        if let statusCode = (socket.response as? HTTPURLResponse)?.statusCode,
           statusCode == 401 || statusCode == 403 {
            return CloudDictationError.authenticationFailed
        }
        return error
    }

    /// Closes a connection that was never (or is no longer) installed and
    /// drops its transcript segment.
    private func discard(_ connection: RealtimeConnection) async {
        connection.receiveTask.cancel()
        connection.socket.cancel(with: .goingAway, reason: nil)
        await longFormTranscript.removeSegment(connection.segmentID)
    }

    private func openConnection(
        forceCredentialRefresh: Bool
    ) async throws -> RealtimeConnection {
        let segmentID = UUID()
        await longFormTranscript.registerSegment(segmentID)
        let socket: URLSessionWebSocketTask
        do {
            socket = try await makeSocket(forceCredentialRefresh: forceCredentialRefresh)
        } catch {
            await longFormTranscript.removeSegment(segmentID)
            throw error
        }
        let writer = RealtimeWebSocketWriter(socket: socket)
        let accumulator = RealtimeTranscriptAccumulator()
        let sessionReadiness = RealtimeSessionReadiness()

        socket.resume()
        let receiveTask = Task { [weak self, socket, accumulator, sessionReadiness] in
            do {
                try await self?.receiveEvents(
                    from: socket,
                    segmentID: segmentID,
                    accumulator: accumulator,
                    sessionReadiness: sessionReadiness
                )
            } catch {
                await sessionReadiness.fail(error)
                await accumulator.fail(error)
                guard !Task.isCancelled, let self else { return }
                let isActiveConnection = self.stateLock.withLock {
                    !self.hasStopped && self.connection?.segmentID == segmentID
                }
                if isActiveConnection {
                    self.recordTerminalError(error)
                }
            }
        }

        // One deadline covers the whole handshake. `sendSessionUpdate` first
        // waits for the websocket upgrade, which is otherwise bounded only by
        // the request's 90-second timeout, so a readiness timeout that starts
        // afterwards cannot bound arming. Cancelling the socket at the
        // deadline fails a pending send immediately.
        let handshakeDeadline = Task { [socket, sessionReadiness] in
            let deadline = UInt64(Self.connectionHandshakeTimeoutSeconds * 1_000_000_000)
            guard (try? await Task.sleep(nanoseconds: deadline)) != nil else { return }
            await sessionReadiness.fail(CloudDictationError.timedOut)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { handshakeDeadline.cancel() }

        do {
            try await sendSessionUpdate(writer: writer)
            try await sessionReadiness.waitUntilReady(timeoutSeconds: Self.connectionHandshakeTimeoutSeconds)
            return RealtimeConnection(
                segmentID: segmentID,
                socket: socket,
                writer: writer,
                accumulator: accumulator,
                receiveTask: receiveTask
            )
        } catch {
            receiveTask.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            await longFormTranscript.removeSegment(segmentID)
            // Prefer the readiness failure: it carries the deadline timeout or
            // the receive loop's error rather than the cancelled send.
            let failure = await sessionReadiness.failure ?? error
            throw Self.connectionError(for: socket, underlying: failure)
        }
    }


    private func scheduleConnectionRollover() {
        let task = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.connectionRolloverIntervalSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await self?.rolloverConnectionWithRetry()
        }
        // Checked under the lock so a rollover finishing after `stop()` or
        // `cancel()` cannot install a timer that nothing will cancel.
        let scheduled = stateLock.withLock { () -> Bool in
            guard !hasStopped else { return false }
            rolloverTask = task
            return true
        }
        if !scheduled {
            task.cancel()
        }
    }

    private func rolloverConnectionWithRetry() async {
        var lastError: Error?
        for attempt in 1...12 {
            guard !Task.isCancelled, !isStopped else { return }
            do {
                try await rolloverConnection()
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
                Self.logger.error(
                    "Realtime connection rollover attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if Self.isNonRetryableConnectionError(error) {
                    break
                }
                if attempt < 12 {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
        }
        if let lastError,
           !Task.isCancelled,
           !isStopped {
            recordTerminalError(lastError)
        }
    }

    private func rolloverConnection() async throws {
        guard let audioRouter = stateLock.withLock({ connection == nil ? nil : self.audioRouter }) else {
            throw CloudDictationError.invalidResponse
        }

        // Prefer a natural speech boundary so the provider never has to split
        // one spoken word across two transcription sessions. Continuous speech
        // still rolls after the bounded wait, well before OpenAI's 60-minute
        // cap. Wait before opening the replacement: an idle replacement socket
        // can be closed while it waits, and its errors are not reported until
        // it becomes the active connection.
        try await waitForQuietRolloverBoundary(maximumWaitSeconds: 3 * 60)

        let newConnection = try await openConnection(forceCredentialRefresh: true)
        do {
            guard !Task.isCancelled, !isStopped else {
                throw CancellationError()
            }
            // Speech may have resumed during the handshake, so briefly
            // re-align with a pause, then make sure the replacement is still
            // open before routing audio to it. An unhealthy replacement is
            // discarded and retried while the old connection keeps recording.
            try await waitForQuietRolloverBoundary(maximumWaitSeconds: 5)
            guard await newConnection.isHealthy() else {
                throw CloudDictationError.networkUnavailable
            }
        } catch {
            await discard(newConnection)
            throw error
        }

        // Swap under the lock, atomically with respect to `stop()` and
        // `cancel()`: once either has run, the replacement is torn down here
        // instead of being installed where nothing would ever close it. The
        // old connection stays reachable as `retiringConnection` so `cancel()`
        // can close it while it is being finalized.
        let oldConnection = stateLock.withLock { () -> RealtimeConnection? in
            guard !hasStopped, let oldConnection = connection else { return nil }
            connection = newConnection
            retiringConnection = oldConnection
            return oldConnection
        }
        guard let oldConnection else {
            await discard(newConnection)
            throw CancellationError()
        }

        // Audio keeps flowing to the old socket while the new credential and
        // handshake are prepared. `replaceWriter` returns only after any append
        // already routed to the old writer has been sent, so the old commit
        // below covers every chunk the old session received.
        await audioRouter.replaceWriter(with: newConnection.writer)

        // Finalize in an unstructured task: `stop()` cancels the rollover task,
        // but the retired segment's transcript is still needed for its result.
        await Task { [self] in
            await finalizeRetiredConnection(oldConnection)
        }.value

        Self.logger.notice("Realtime connection rolled over without stopping microphone capture")
        scheduleConnectionRollover()
    }

    private func finalizeRetiredConnection(_ oldConnection: RealtimeConnection) async {
        do {
            try await oldConnection.writer.commit()
            let segmentTranscript = try await oldConnection.accumulator.waitForFinal(timeoutSeconds: 90)
            _ = await longFormTranscript.completeSegment(
                oldConnection.segmentID,
                transcript: segmentTranscript
            )
        } catch {
            // The streamed deltas are already durable. If finalization of the
            // retired segment fails, freeze its best partial text and keep the
            // new socket recording instead of losing the entire dictation.
            let partial = await oldConnection.accumulator.snapshot()
            _ = await longFormTranscript.completeSegment(
                oldConnection.segmentID,
                transcript: partial
            )
            Self.logger.error(
                "Retired realtime segment finalized from checkpoint after rollover error: \(error.localizedDescription, privacy: .public)"
            )
        }
        // Rendered from the combined transcript, so text the new connection
        // streamed meanwhile is kept rather than overwritten.
        await persistRecoveryCheckpoint()

        oldConnection.receiveTask.cancel()
        oldConnection.socket.cancel(with: .normalClosure, reason: nil)
        stateLock.withLock {
            if retiringConnection?.segmentID == oldConnection.segmentID {
                retiringConnection = nil
            }
        }
    }

    private func waitForQuietRolloverBoundary(
        maximumWaitSeconds: TimeInterval
    ) async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        while true {
            guard !Task.isCancelled,
                  stateLock.withLock({ !hasStopped }) else {
                throw CancellationError()
            }
            let isQuiet = stateLock.withLock { () -> Bool in
                guard let lastAudibleAt else { return true }
                let quietDuration = lastAudibleAt.duration(to: clock.now)
                let quietSeconds = Double(quietDuration.components.seconds)
                    + Double(quietDuration.components.attoseconds) / 1_000_000_000_000_000_000
                return quietSeconds >= 0.45
            }
            if isQuiet {
                return
            }
            let elapsed = startedAt.duration(to: clock.now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            if elapsedSeconds >= maximumWaitSeconds {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func makeSocket(
        forceCredentialRefresh: Bool
    ) async throws -> URLSessionWebSocketTask {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]
        guard let url = components.url else {
            throw CloudDictationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue(
            "Bearer \(try await authTokenProvider(forceCredentialRefresh))",
            forHTTPHeaderField: "Authorization"
        )
        return session.webSocketTask(with: request)
    }

    private func sendSessionUpdate(writer: RealtimeWebSocketWriter) async throws {
        let transcription = OpenAIRealtimeTranscriptionConfiguration.payload(
            model: model,
            localeIdentifier: localeIdentifier,
            hints: transcriptionHints.map(\.preferred)
        )
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
        segmentID: UUID,
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
                // Appends are O(delta). The combined transcript is rendered,
                // published and checkpointed by the throttle, not per delta.
                let partialCharacterCount = await accumulator.appendDelta(delta)
                await longFormTranscript.appendPartial(segmentID, delta: delta)
                if deltaCount <= 12 || deltaCount.isMultiple(of: 50) {
                    Self.logger.notice(
                        "RealtimeDiag: delta #\(deltaCount, privacy: .public) item=\(itemID, privacy: .public) deltaChars=\(delta.count, privacy: .public) partialChars=\(partialCharacterCount, privacy: .public)"
                    )
                }
                stateLock.withLock { partialTranscriptThrottle }?.signal()
            }
            if type == "conversation.item.input_audio_transcription.completed",
               let transcript = payload["transcript"] as? String {
                completedCount += 1
                Self.logger.notice(
                    "RealtimeDiag: completed event #\(completedCount, privacy: .public) item=\(itemID, privacy: .public) chars=\(transcript.count, privacy: .public) +\(self.diagElapsedMS(), privacy: .public)ms"
                )
                if !firstCompletedDelivered {
                    firstCompletedDelivered = true
                    let completedText = Self.normalizeText(transcript)
                    let finalText = await accumulator.complete(completedText)
                    _ = await longFormTranscript.completeSegment(
                        segmentID,
                        transcript: finalText
                    )
                    stateLock.withLock { partialTranscriptThrottle }?.signal()
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
        // Bring the checkpoint up to date first: the controller recovers the
        // transcript from it as soon as it handles the error.
        Task {
            await self.persistRecoveryCheckpoint()
            DispatchQueue.main.async {
                self.onTerminalError(error)
            }
        }
    }

    /// Throttled: delivers the combined transcript to the UI and rewrites the
    /// checkpoint without forcing a disk flush.
    private func publishPartialTranscript() async {
        let snapshot = await longFormTranscript.snapshot()
        stateLock.withLock { recoveryCheckpoint }?.replace(
            with: snapshot.text,
            revision: snapshot.revision,
            synchronize: false
        )
        if !snapshot.text.isEmpty {
            onPartialText(snapshot.text)
        }
    }

    /// Writes the combined transcript to the checkpoint and flushes it.
    @discardableResult
    private func persistRecoveryCheckpoint() async -> String {
        let snapshot = await longFormTranscript.snapshot()
        stateLock.withLock { recoveryCheckpoint }?.replace(
            with: snapshot.text,
            revision: snapshot.revision
        )
        return snapshot.text
    }

    func recoveryTranscript() -> String {
        stateLock.withLock { recoveryCheckpoint }?.snapshot()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func discardRecoveryCheckpoint() {
        let checkpoint = stateLock.withLock { () -> RealtimeDictationRecoveryCheckpoint? in
            defer { recoveryCheckpoint = nil }
            return recoveryCheckpoint
        }
        checkpoint?.discard()
    }

    func preserveRecoveryCheckpoint() {
        let checkpoint = stateLock.withLock { () -> RealtimeDictationRecoveryCheckpoint? in
            defer { recoveryCheckpoint = nil }
            return recoveryCheckpoint
        }
        checkpoint?.preserveForNextLaunch()
    }

    static func pendingRecoveryTranscripts() -> [RealtimeDictationRecoveryCheckpoint.PendingRecovery] {
        RealtimeDictationRecoveryCheckpoint.pendingRecoveries()
    }

    static func discardPendingRecoveryTranscripts(
        _ recoveries: [RealtimeDictationRecoveryCheckpoint.PendingRecovery]
    ) {
        RealtimeDictationRecoveryCheckpoint.discardPending(recoveries)
    }

    fileprivate static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A completed event normally supersedes streaming deltas, but providers
    /// can occasionally return a visibly truncated completion for a long turn.
    /// Keep the partial stream when the completion would discard a substantial
    /// portion of speech the user already saw and Voce already checkpointed.
    static func preferredCompletedTranscript(partial: String, completed: String) -> String {
        let normalizedPartial = normalizeText(partial)
        let normalizedCompleted = normalizeText(completed)
        guard !normalizedPartial.isEmpty else { return normalizedCompleted }
        guard !normalizedCompleted.isEmpty else { return normalizedPartial }

        let minimumCredibleCompletedLength = Int(Double(normalizedPartial.count) * 0.75)
        if normalizedCompleted.count < minimumCredibleCompletedLength {
            return normalizedPartial
        }
        return normalizedCompleted
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

    static var realtimeTargetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }

    static func convertToRealtimePCMData(_ buffer: AVAudioPCMBuffer) -> RealtimePCMConversion? {
        convertToRealtimePCMData(buffer, using: CachedPCMConverter(outputFormat: realtimeTargetFormat))
    }

    static func convertToRealtimePCMData(
        _ buffer: AVAudioPCMBuffer,
        using converter: CachedPCMConverter
    ) -> RealtimePCMConversion? {
        var data = Data()
        var outputFrameCount = 0
        let converted = converter.convert(buffer) { targetBuffer in
            if let chunk = pcmData(from: targetBuffer) {
                data.append(chunk)
                outputFrameCount += Int(targetBuffer.frameLength)
            }
        }
        guard converted, !data.isEmpty else { return nil }
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

/// Runs `action` at most once per `interval` however often `signal()` is
/// called, and always once more after the last signal, so the latest state
/// is delivered. Runs never overlap. After `invalidate()` nothing more runs.
final class CoalescingThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let action: @Sendable () async -> Void
    private let lock = NSLock()
    private var isSignaled = false
    private var isScheduled = false
    private var isInvalidated = false
    private var lastRunAt: ContinuousClock.Instant?

    init(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.action = action
    }

    func signal() {
        let delay = lock.withLock { () -> TimeInterval? in
            guard !isInvalidated else { return nil }
            isSignaled = true
            guard !isScheduled else { return nil }
            isScheduled = true
            return remainingDelay()
        }
        if let delay {
            schedule(after: delay)
        }
    }

    func invalidate() {
        lock.withLock { isInvalidated = true }
    }

    /// Must be called with `lock` held.
    private func remainingDelay() -> TimeInterval {
        guard let lastRunAt else { return 0 }
        let elapsed = lastRunAt.duration(to: ContinuousClock().now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, interval - elapsedSeconds)
    }

    private func schedule(after delay: TimeInterval) {
        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self.run()
        }
    }

    private func run() async {
        let shouldRun = lock.withLock { () -> Bool in
            guard !isInvalidated else {
                isScheduled = false
                return false
            }
            isSignaled = false
            lastRunAt = ContinuousClock().now
            return true
        }
        guard shouldRun else { return }
        await action()
        let nextDelay = lock.withLock { () -> TimeInterval? in
            guard isSignaled, !isInvalidated else {
                isScheduled = false
                return nil
            }
            return remainingDelay()
        }
        if let nextDelay {
            schedule(after: nextDelay)
        }
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

    var failure: Error? {
        guard case .failure(let error) = result else { return nil }
        return error
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

/// Converts capture buffers to a fixed output format, reusing one
/// `AVAudioConverter` until the input format changes (for example after the
/// input device switches) instead of allocating a converter per buffer.
/// Each buffer is still converted as a complete stream and the converter is
/// reset afterwards, so output matches a freshly created converter.
final class CachedPCMConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// Calls `body` with each non-empty converted buffer. Returns `false` if
    /// no converter exists for the input format or conversion fails.
    func convert(_ buffer: AVAudioPCMBuffer, _ body: (AVAudioPCMBuffer) -> Void) -> Bool {
        lock.withLock {
            let converter: AVAudioConverter
            if let cached = self.converter, cached.inputFormat == buffer.format {
                converter = cached
            } else {
                guard let created = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                    self.converter = nil
                    return false
                }
                self.converter = created
                converter = created
            }
            defer { converter.reset() }

            let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
            let capacity = max(1_024, AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024)
            let inputProvider = PCMConverterSingleBufferInput(buffer: buffer)
            while true {
                guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    return false
                }
                var conversionError: NSError?
                let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                    inputProvider.next(outStatus: outStatus)
                }
                guard conversionError == nil, status != .error else { return false }
                if targetBuffer.frameLength > 0 {
                    body(targetBuffer)
                }
                if status == .endOfStream || status == .inputRanDry {
                    return true
                }
                if status == .haveData, targetBuffer.frameLength == 0 {
                    return true
                }
            }
        }
    }
}

private final class PCMConverterSingleBufferInput: @unchecked Sendable {
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

private actor RealtimeAudioRouter {
    private var writer: RealtimeWebSocketWriter
    private var appendsInFlight = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(writer: RealtimeWebSocketWriter) {
        self.writer = writer
    }

    func appendAudio(_ data: Data) async throws {
        // Actor reentrancy lets `replaceWriter` run while this append is
        // suspended, so track it to let the swap wait for it.
        let writer = writer
        appendsInFlight += 1
        defer {
            appendsInFlight -= 1
            if appendsInFlight == 0 {
                let waiters = drainWaiters
                drainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        try await writer.appendAudio(data)
    }

    /// Routes later appends to `writer`, returning once every append already
    /// routed to the previous writer has finished sending.
    func replaceWriter(with writer: RealtimeWebSocketWriter) async {
        self.writer = writer
        guard appendsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }
}

actor RealtimeLongFormTranscript {
    struct Snapshot: Sendable {
        let text: String
        /// Increases with every change, so writers can drop stale renders.
        let revision: UInt64
    }

    private struct Segment {
        var partial = ""
        var completed: String?
    }

    private var order: [UUID] = []
    private var segments: [UUID: Segment] = [:]
    private var revision: UInt64 = 0

    func reset() {
        order.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func registerSegment(_ id: UUID) {
        guard segments[id] == nil else { return }
        order.append(id)
        segments[id] = Segment()
        revision &+= 1
    }

    func removeSegment(_ id: UUID) {
        order.removeAll { $0 == id }
        segments[id] = nil
        revision &+= 1
    }

    func updatePartial(_ id: UUID, transcript: String) -> String {
        guard var segment = segments[id], segment.completed == nil else {
            return renderedTranscript()
        }
        segment.partial = transcript
        segments[id] = segment
        revision &+= 1
        return renderedTranscript()
    }

    /// Appends a streamed delta in place (no copy of the running text).
    func appendPartial(_ id: UUID, delta: String) {
        guard let segment = segments[id], segment.completed == nil else { return }
        segments[id]?.partial.append(delta)
        revision &+= 1
    }

    func snapshot() -> Snapshot {
        Snapshot(text: renderedTranscript(), revision: revision)
    }

    func completeSegment(_ id: UUID, transcript: String) -> String {
        guard var segment = segments[id] else {
            return renderedTranscript()
        }
        if segment.completed == nil {
            let completed = OpenAIRealtimeWhisperCaptureSession.preferredCompletedTranscript(
                partial: segment.partial,
                completed: transcript
            )
            segment.completed = completed
            segment.partial = completed
            segments[id] = segment
            revision &+= 1
        }
        return renderedTranscript()
    }

    func renderedTranscript() -> String {
        let transcripts = order.compactMap { id -> String? in
            guard let segment = segments[id] else { return nil }
            let text = segment.completed ?? segment.partial
            let normalized = OpenAIRealtimeWhisperCaptureSession.normalizeText(text)
            return normalized.isEmpty ? nil : normalized
        }
        return transcripts.joined(separator: " ")
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
    private var partialCharacterCount = 0
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<Result<String, Error>, Never>?

    /// Returns the running character count; re-normalizing the whole partial
    /// text on every delta made long dictations quadratic.
    @discardableResult
    func appendDelta(_ delta: String) -> Int {
        partialText += delta
        partialCharacterCount += delta.count
        return partialCharacterCount
    }

    @discardableResult
    func complete(_ transcript: String) -> String {
        if let result {
            switch result {
            case .success(let completed):
                return completed
            case .failure:
                return transcript
            }
        }
        let finalTranscript = OpenAIRealtimeWhisperCaptureSession.preferredCompletedTranscript(
            partial: partialText,
            completed: transcript
        )
        result = .success(finalTranscript)
        continuation?.resume(returning: .success(finalTranscript))
        continuation = nil
        return finalTranscript
    }

    func fail(_ error: Error) {
        guard result == nil else { return }
        result = .failure(error)
        continuation?.resume(returning: .failure(error))
        continuation = nil
    }

    func snapshot() -> String {
        OpenAIRealtimeWhisperCaptureSession.normalizeText(partialText)
    }

    /// `false` once the receive loop failed or the final transcript arrived.
    var isOpen: Bool {
        result == nil
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
