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
    private let transcriptionHints: [LexiconEntry]

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () throws -> String,
        transcriptionModel: String = "gpt-realtime-whisper",
        refinementModel: String = "gpt-4o-mini",
        transcriptionHints: [LexiconEntry] = []
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.transcriptionModel = transcriptionModel
        self.transcriptionHints = Array(transcriptionHints.prefix(200))
        self.batchClient = OpenAICloudSpeechProviderClient(
            session: session,
            apiKeyProvider: apiKeyProvider,
            refinementModel: refinementModel,
            transcriptionHints: transcriptionHints
        )
    }

    func preflightCheck(localeIdentifier: String) async throws {
        try await batchClient.preflightCheck(localeIdentifier: localeIdentifier)
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let locale = Self.effectiveLanguageCode(from: hints.first ?? localeIdentifier)
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
            return try await withTimeout(seconds: 90) {
                try await receiveTask.value
            }
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
        let transcription: [String: Any] = [
            "model": transcriptionModel,
            "language": locale
        ]

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

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CloudDictationError.timedOut
            }
            guard let value = try await group.next() else {
                throw CloudDictationError.timedOut
            }
            group.cancelAll()
            return value
        }
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

    private static func effectiveLanguageCode(from localeIdentifier: String) -> String {
        let components = localeIdentifier.split(separator: "-")
        return components.first.map(String.init) ?? "en"
    }

    private static func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
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
