import Foundation
import OSLog
import VoceKit

protocol CloudSpeechProviderClient: Sendable {
    func preflightCheck(localeIdentifier: String) async throws
    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript
    func refine(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) async throws -> String
}

enum CloudDictationError: LocalizedError {
    case missingAPIKey
    case authenticationRequired
    case subscriptionRequired
    case invalidResponse
    case invalidAudioFile
    case emptyTranscript
    case authenticationFailed
    case rateLimited
    case timedOut
    case networkUnavailable
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Cloud dictation unavailable: missing OpenAI API key."
        case .authenticationRequired:
            return "Cloud dictation unavailable: verify your email to use cloud dictation."
        case .subscriptionRequired:
            return "Cloud dictation unavailable: Voce Pro is required."
        case .invalidResponse:
            return "Cloud dictation unavailable: invalid provider response."
        case .invalidAudioFile:
            return "Cloud dictation unavailable: audio capture could not be read."
        case .emptyTranscript:
            return "Cloud dictation unavailable: no speech was captured."
        case .authenticationFailed:
            return "Cloud dictation unavailable: OpenAI authentication failed."
        case .rateLimited:
            return "Cloud dictation unavailable: OpenAI rate limit reached."
        case .timedOut:
            return "Cloud dictation unavailable: request timed out."
        case .networkUnavailable:
            return "Cloud dictation unavailable: network connection failed."
        case .providerError(let message):
            return "Cloud dictation unavailable: \(message)"
        }
    }
}

struct OpenAICloudSpeechProviderClient: CloudSpeechProviderClient {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "OpenAICloudSpeech")

    private struct ChatCompletionsRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct ResponseFormat: Encodable {
            struct JSONSchema: Encodable {
                struct Schema: Encodable {
                    struct TextProperty: Encodable {
                        var type = "string"
                    }

                    var type = "object"
                    var properties = ["text": TextProperty()]
                    var required = ["text"]
                    var additionalProperties = false
                }

                var name = "voce_refined_transcript"
                var strict = true
                var schema = Schema()
            }

            var type = "json_schema"
            var json_schema = JSONSchema()

            static let refinedTranscript = ResponseFormat()
        }

        var model: String
        var messages: [Message]
        var temperature: Double
        var max_completion_tokens: Int
        var response_format: ResponseFormat?
    }

    private struct ChatCompletionsResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String
            }

            var message: Message
        }

        var choices: [Choice]
    }

    private let session: URLSession
    private let apiKeyProvider: @Sendable () throws -> String
    private let refinementModel: String

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () throws -> String,
        refinementModel: String = "gpt-4o-mini"
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.refinementModel = refinementModel
    }

    static func makeDefault(
        dictation: AppPreferences.Dictation,
        credentialStore: CloudProviderCredentialStore = .shared
    ) -> OpenAICloudSpeechProviderClient {
        OpenAICloudSpeechProviderClient(
            apiKeyProvider: {
                do {
                    return try credentialStore.resolveOpenAIAPIKey(source: dictation.cloud.apiKeySource)
                } catch CloudProviderCredentialStoreError.missingAPIKey {
                    throw CloudDictationError.missingAPIKey
                } catch {
                    throw error
                }
            }
        )
    }

    func preflightCheck(localeIdentifier: String) async throws {
        _ = try resolveAPIKey()
        Self.logger.notice("Running cloud dictation preflight for locale \(localeIdentifier, privacy: .public)")

        let request = ChatCompletionsRequest(
            model: refinementModel,
            messages: [
                .init(role: "system", content: "You are a connectivity check. Reply with READY."),
                .init(role: "user", content: "Locale: \(localeIdentifier)")
            ],
            temperature: 0,
            max_completion_tokens: 12,
            response_format: nil
        )

        let response = try await sendJSONRequest(
            path: "/v1/chat/completions",
            body: request,
            timeout: 15
        )
        Self.logger.notice("Cloud dictation preflight completed successfully")
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: response)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw CloudDictationError.invalidResponse
        }
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        throw CloudDictationError.providerError(
            "Standard cloud transcription has been removed. Use Realtime Whisper cloud transcription."
        )
    }

    func refine(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) async throws -> String {
        Self.logger.notice(
            "Starting OpenAI transcript refinement with \(transcript.count, privacy: .public) input characters and \(dictionary.count, privacy: .public) lexicon entries"
        )
        let prompt = Self.buildRefinementPrompt(
            transcript: transcript,
            localeIdentifier: localeIdentifier,
            dictionary: dictionary,
            profile: profile,
            appContext: appContext
        )

        let request = ChatCompletionsRequest(
            model: refinementModel,
            messages: [
                .init(role: "system", content: prompt.system),
                .init(role: "user", content: prompt.user)
            ],
            temperature: 0.1,
            max_completion_tokens: 700,
            response_format: .refinedTranscript
        )

        let clock = ContinuousClock()
        let requestStartedAt = clock.now
        let data = try await sendJSONRequest(
            path: "/v1/chat/completions",
            body: request,
            timeout: 45
        )
        let requestElapsed = requestStartedAt.duration(to: clock.now)
        Self.logger.notice(
            "OpenAI transcript refinement request finished in \(Self.seconds(from: requestElapsed), format: .fixed(precision: 2))s"
        )

        let decodeStartedAt = clock.now
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw CloudDictationError.invalidResponse
        }

        let parsed = extractJSONPayload(from: content)
        let refined = normalizeText(parsed["text"]?.stringValue ?? "")
        let decodeElapsed = decodeStartedAt.duration(to: clock.now)
        Self.logger.notice(
            "OpenAI transcript refinement decoded in \(Self.seconds(from: decodeElapsed), format: .fixed(precision: 2))s with \(refined.count, privacy: .public) output characters"
        )
        guard !refined.isEmpty else {
            throw CloudDictationError.invalidResponse
        }
        return refined
    }

    private func sendJSONRequest<Body: Encodable>(
        path: String,
        body: Body,
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(try resolveAPIKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request: request)
        try validateHTTPResponse(response, data: data)
        return data
    }

    private func send(request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw CloudDictationError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw CloudDictationError.networkUnavailable
            default:
                throw CloudDictationError.providerError(error.localizedDescription)
            }
        } catch {
            throw CloudDictationError.providerError(error.localizedDescription)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudDictationError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Request failed."
            Self.logger.error(
                "OpenAI request failed with status \(httpResponse.statusCode, privacy: .public): \(message, privacy: .public)"
            )
            switch httpResponse.statusCode {
            case 401, 403:
                throw CloudDictationError.authenticationFailed
            case 429:
                throw CloudDictationError.rateLimited
            default:
                throw CloudDictationError.providerError(message)
            }
        }
    }

    private func resolveAPIKey() throws -> String {
        do {
            return try apiKeyProvider()
        } catch CloudDictationError.missingAPIKey {
            throw CloudDictationError.missingAPIKey
        } catch CloudProviderCredentialStoreError.missingAPIKey {
            throw CloudDictationError.missingAPIKey
        } catch {
            throw CloudDictationError.providerError(error.localizedDescription)
        }
    }

    static func buildRefinementPrompt(
        transcript: String,
        localeIdentifier: String,
        dictionary: [LexiconEntry],
        profile: StyleProfile,
        appContext: AppContext?
    ) -> (system: String, user: String) {
        let serializedDictionary = Self.dictionaryPayload(entries: dictionary)
        let appDescription = appContext.map { "\($0.appName) (\($0.bundleIdentifier))" } ?? "unknown"
        let system = """
        Refine speech-to-text dictation for insertion. Return compact JSON only: {"text":"..."}.
        Preserve intent and wording unless a correction is explicitly spoken.
        Correct obvious speech-recognition errors when the surrounding words make the intended phrase clear, including tense errors contradicted by time references.
        Example: "I've been meeting with Vector Corp tomorrow" -> "I have a meeting with Vector Corp tomorrow."
        Resolve self-corrections: "no", "I mean", "or I meant", "actually", "no actually", "wait no", "rather", "scratch that", "sorry", and "replace X with Y".
        When the speaker revises a place, person, object, action, or choice, keep only the final intended version.
        Examples: "Yesterday I went to Publix or I meant Lowes to pick up groceries" -> "Yesterday I went to Lowes to pick up groceries."; "Let's do xyz no actually let's do abc" -> "Let's do abc."
        Preserve dictionary spellings when present or strongly implied.
        Use bullets only when the transcript clearly represents requirements, tasks, criteria, ingredients, steps, or grouped attributes. Otherwise return a paragraph.
        Do not add headings, summarize away substance, or add marketing language or PM-speak.
        Keep punctuation clean and natural.
        """
        let user = """
        Locale: \(localeIdentifier)
        App: \(appDescription)
        Style profile: tone=\(profile.tone.rawValue), structure=\(profile.structureMode.rawValue), filler=\(profile.fillerPolicy.rawValue), command=\(profile.commandPolicy.rawValue)
        Dictionary:
        \(serializedDictionary)

        Transcript:
        \(transcript)
        """
        return (system, user)
    }

    private static func dictionaryPayload(entries: [LexiconEntry]) -> String {
        let prioritized = entries.prefix(200).map { entry in
            switch entry.scope {
            case .global:
                return "- [global] \(entry.term) -> \(entry.preferred)"
            case .app(let bundleID):
                return "- [app:\(bundleID)] \(entry.term) -> \(entry.preferred)"
            }
        }
        if prioritized.isEmpty {
            return "- none"
        }
        return prioritized.joined(separator: "\n")
    }

    private func extractJSONPayload(from content: String) -> [String: JSONValue] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}") else {
            return [:]
        }
        let jsonText = String(trimmed[first ... last])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.mapValues(JSONValue.init)
    }

    private func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(_ value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init))
        case let array as [Any]:
            self = .array(array.map(JSONValue.init))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
