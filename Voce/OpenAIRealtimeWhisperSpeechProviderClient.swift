@preconcurrency import AVFoundation
import Foundation
import OSLog
import VoceKit

struct OpenAIRealtimeWhisperSpeechProviderClient: CloudSpeechProviderClient {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "OpenAIRealtimeWhisper")

    private let session: URLSession
    private let apiKeyProvider: @Sendable () throws -> String
    private let transcriptionModel: String
    private let batchClient: OpenAICloudSpeechProviderClient

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () throws -> String,
        transcriptionModel: String = OpenAIRealtimeTranscriptionConfiguration.defaultModel,
        refinementModel: String = "gpt-4o-mini"
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.transcriptionModel = transcriptionModel
        self.batchClient = OpenAICloudSpeechProviderClient(
            session: session,
            apiKeyProvider: apiKeyProvider,
            refinementModel: refinementModel
        )
    }

    func preflightCheck(localeIdentifier: String) async throws {
        try await batchClient.preflightCheck(localeIdentifier: localeIdentifier)
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let locale = Self.languageCode(fromHints: hints, fallbackLocaleIdentifier: localeIdentifier)
        let transcript = try await runRealtimeTranscription(
            audioURL: audioURL,
            locale: locale,
            prompt: ""
        )
        let elapsed = startedAt.duration(to: clock.now)
        Self.logger.notice(
            "OpenAI Realtime Whisper transcription completed in \(Self.seconds(from: elapsed), format: .fixed(precision: 2))s with \(transcript.count, privacy: .public) characters"
        )
        guard !transcript.isEmpty else {
            throw CloudDictationError.emptyTranscript
        }
        return RawTranscript(
            text: transcript,
            segments: [],
            durationMS: await CloudAudioUploadPreparation.audioDurationMilliseconds(for: audioURL)
        )
    }

    func refine(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) async throws -> String {
        try await batchClient.refine(
            transcript: transcript,
            localeIdentifier: localeIdentifier,
            dictionary: dictionary,
            profile: profile,
            appContext: appContext
        )
    }

    private func runRealtimeTranscription(
        audioURL: URL,
        locale: String,
        prompt: String
    ) async throws -> String {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription")
        ]
        guard let url = components.url else {
            throw CloudDictationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("Bearer \(try apiKeyProvider())", forHTTPHeaderField: "Authorization")

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let receiveTask = Task {
            try await receiveTranscript(from: socket)
        }

        do {
            try await sendSessionUpdate(socket: socket, locale: locale, prompt: prompt)
            try await streamAudioFile(audioURL, to: socket)
            try await sendJSON(["type": "input_audio_buffer.commit"], to: socket)
            // On timeout the deferred socket cancel ends the receive task.
            return try await Self.value(of: receiveTask, timeoutSeconds: 90)
        } catch {
            receiveTask.cancel()
            throw error
        }
    }

    private func sendSessionUpdate(
        socket: URLSessionWebSocketTask,
        locale: String,
        prompt: String
    ) async throws {
        let transcription = OpenAIRealtimeTranscriptionConfiguration.payload(
            model: transcriptionModel,
            localeIdentifier: locale,
            hints: []
        )

        try await sendJSON(
            [
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
            ],
            to: socket
        )
    }

    private func streamAudioFile(_ audioURL: URL, to socket: URLSessionWebSocketTask) async throws {
        let sourceFile = try AVAudioFile(forReading: audioURL)
        let sourceFormat = sourceFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw CloudDictationError.invalidAudioFile
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw CloudDictationError.invalidAudioFile
        }

        let sourceCapacity = AVAudioFrameCount(sourceFormat.sampleRate / 10)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: max(sourceCapacity, 1)
        ) else {
            throw CloudDictationError.invalidAudioFile
        }

        while sourceFile.framePosition < sourceFile.length {
            let remaining = AVAudioFrameCount(sourceFile.length - sourceFile.framePosition)
            sourceBuffer.frameLength = min(sourceBuffer.frameCapacity, remaining)
            try sourceFile.read(into: sourceBuffer, frameCount: sourceBuffer.frameLength)
            guard sourceBuffer.frameLength > 0 else { break }

            let ratio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
            let targetCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 512
            guard let targetBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(targetCapacity, 1)
            ) else {
                throw CloudDictationError.invalidAudioFile
            }

            let inputProvider = ConverterInputProvider(buffer: sourceBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                inputProvider.next(outStatus: outStatus)
            }
            if let conversionError {
                throw CloudDictationError.providerError(conversionError.localizedDescription)
            }
            guard status != .error else {
                throw CloudDictationError.invalidAudioFile
            }
            guard let data = Self.pcmData(from: targetBuffer), !data.isEmpty else {
                continue
            }
            try await sendJSON(
                [
                    "type": "input_audio_buffer.append",
                    "audio": data.base64EncodedString()
                ],
                to: socket
            )
        }

        // Each chunk above leaves the converter waiting for more input, so its
        // resampler still holds the tail of the audio. Signal end of input and
        // send what it drains, or the final words are never transcribed.
        while true {
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
                throw CloudDictationError.invalidAudioFile
            }
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw CloudDictationError.providerError(conversionError.localizedDescription)
            }
            guard status != .error else {
                throw CloudDictationError.invalidAudioFile
            }
            if targetBuffer.frameLength > 0,
               let data = Self.pcmData(from: targetBuffer),
               !data.isEmpty {
                try await sendJSON(
                    [
                        "type": "input_audio_buffer.append",
                        "audio": data.base64EncodedString()
                    ],
                    to: socket
                )
            }
            if status == .endOfStream || targetBuffer.frameLength == 0 {
                break
            }
        }
    }

    private func receiveTranscript(from socket: URLSessionWebSocketTask) async throws -> String {
        var completedTurns: [String] = []
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

            if type == "conversation.item.input_audio_transcription.completed",
               let transcript = payload["transcript"] as? String {
                let normalized = Self.normalizeText(transcript)
                if !normalized.isEmpty {
                    completedTurns.append(normalized)
                }
                return Self.normalizeText(completedTurns.joined(separator: " "))
            }
        }

        throw CloudDictationError.timedOut
    }

    private func sendJSON(_ object: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CloudDictationError.invalidResponse
        }
        try await socket.send(.string(string))
    }

    /// Returns `task`'s value or throws `timedOut`. A task-group race cannot
    /// time out here: the group waits for every child, and awaiting
    /// `task.value` ignores cancellation while `socket.receive()` is pending.
    /// The losing waiter is an unstructured task that resumes a one-shot
    /// continuation as a no-op (the pattern from the capture session's
    /// `wait(for:timeoutSeconds:)`); the caller cancels the socket to end it.
    static func value<T: Sendable>(
        of task: Task<T, Error>,
        timeoutSeconds: TimeInterval
    ) async throws -> T {
        let once = OneShotResultContinuation<T>()
        let result = await withCheckedContinuation { continuation in
            once.set(continuation)
            Task {
                once.resume(await task.result)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                once.resume(.failure(CloudDictationError.timedOut))
            }
        }
        return try result.get()
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let audioBuffer = buffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        return Data(bytes: audioBuffer, count: Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uses the first hint that is actually a language or locale code (hints
    /// can carry other text), then the configured locale.
    static func languageCode(fromHints hints: [String], fallbackLocaleIdentifier: String) -> String {
        for hint in hints {
            if let code = validLanguageCode(from: hint) {
                return code
            }
        }
        return validLanguageCode(from: fallbackLocaleIdentifier) ?? "en"
    }

    private static func validLanguageCode(from identifier: String) -> String? {
        let primary = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() } ?? ""
        guard (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }),
              Locale.LanguageCode(primary).isISOLanguage else {
            return nil
        }
        return primary
    }

    private static func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private final class OneShotResultContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, Error>, Never>?

    func set(_ continuation: CheckedContinuation<Result<T, Error>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Result<T, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<T, Error>, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
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
