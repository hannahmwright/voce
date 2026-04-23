import Foundation
import OSLog
import VoceKit

struct VoceCloudProxySpeechProviderClient: CloudSpeechProviderClient {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "VoceCloudProxy")

    #if DEBUG
    private static let siteBaseURL = URL(string: "https://cheerful-raven-194.convex.site")!
    #else
    private static let siteBaseURL = URL(string: "https://combative-ant-133.convex.site")!
    #endif

    private struct PreflightRequest: Encodable {
        var localeIdentifier: String
    }

    private struct PreflightResponse: Decodable {
        var ready: Bool
    }

    private struct TranscriptionResponse: Decodable {
        var text: String
    }

    private struct RefineRequest: Encodable {
        struct SerializedLexiconEntry: Encodable {
            var term: String
            var preferred: String
            var scope: String
            var bundleIdentifier: String?
        }

        struct SerializedStyleProfile: Encodable {
            var tone: String
            var structureMode: String
            var fillerPolicy: String
            var commandPolicy: String
        }

        struct SerializedAppContext: Encodable {
            var bundleIdentifier: String
            var appName: String
            var inputFieldDescription: String?
            var isRemoteDesktop: Bool
            var isIDE: Bool
        }

        var transcript: String
        var localeIdentifier: String
        var dictionary: [SerializedLexiconEntry]
        var profile: SerializedStyleProfile
        var appContext: SerializedAppContext?
    }

    private struct RefineResponse: Decodable {
        var text: String
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    private let session: URLSession
    private let subscriberEmailProvider: @Sendable () -> String?
    private let sessionStore: VoceAccessSessionStore
    private let preflightURL: URL
    private let transcriptionURL: URL
    private let refinementURL: URL

    init(
        session: URLSession = .shared,
        subscriberEmailProvider: @escaping @Sendable () -> String?,
        sessionStore: VoceAccessSessionStore = .shared,
        baseURL: URL = siteBaseURL
    ) {
        self.session = session
        self.subscriberEmailProvider = subscriberEmailProvider
        self.sessionStore = sessionStore
        self.preflightURL = baseURL.appendingPathComponent("cloud-dictation/preflight")
        self.transcriptionURL = baseURL.appendingPathComponent("cloud-dictation/transcribe")
        self.refinementURL = baseURL.appendingPathComponent("cloud-dictation/refine")
    }

    func preflightCheck(localeIdentifier: String) async throws {
        let email = try resolvedSubscriberEmail()
        var request = URLRequest(url: preflightURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        addAuthHeaders(for: email, to: &request)
        request.httpBody = try JSONEncoder().encode(PreflightRequest(localeIdentifier: localeIdentifier))

        let (data, response) = try await send(request: request)
        try validateResponse(response, data: data)
        let decoded = try JSONDecoder().decode(PreflightResponse.self, from: data)
        guard decoded.ready else {
            throw CloudDictationError.invalidResponse
        }
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        let email = try resolvedSubscriberEmail()
        let uploadURL = try await CloudAudioUploadPreparation.preparedUploadURL(for: audioURL)
        let shouldCleanupUploadURL = uploadURL != audioURL
        defer {
            if shouldCleanupUploadURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }

        let audioData = try Data(contentsOf: uploadURL)
        guard !audioData.isEmpty else {
            throw CloudDictationError.invalidAudioFile
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(named: "localeIdentifier", value: localeIdentifier, boundary: boundary)
        let hintsData = try JSONEncoder().encode(hints)
        if let hintsJSON = String(data: hintsData, encoding: .utf8) {
            body.appendMultipartField(named: "hints", value: hintsJSON, boundary: boundary)
        }
        body.appendMultipartFile(
            named: "file",
            filename: uploadURL.lastPathComponent,
            mimeType: CloudAudioUploadPreparation.mimeType(for: uploadURL),
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(for: email, to: &request)
        request.httpBody = body

        let (data, response) = try await send(request: request)
        try validateResponse(response, data: data)

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = normalizeText(decoded.text)
        guard !text.isEmpty else {
            throw CloudDictationError.emptyTranscript
        }

        return RawTranscript(
            text: text,
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
        let email = try resolvedSubscriberEmail()
        var request = URLRequest(url: refinementURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        addAuthHeaders(for: email, to: &request)

        let payload = RefineRequest(
            transcript: transcript,
            localeIdentifier: localeIdentifier,
            dictionary: dictionary.prefix(200).map { entry in
                switch entry.scope {
                case .global:
                    return .init(term: entry.term, preferred: entry.preferred, scope: "global", bundleIdentifier: nil)
                case .app(let bundleID):
                    return .init(term: entry.term, preferred: entry.preferred, scope: "app", bundleIdentifier: bundleID)
                }
            },
            profile: .init(
                tone: profile.tone.rawValue,
                structureMode: profile.structureMode.rawValue,
                fillerPolicy: profile.fillerPolicy.rawValue,
                commandPolicy: profile.commandPolicy.rawValue
            ),
            appContext: appContext.map {
                .init(
                    bundleIdentifier: $0.bundleIdentifier,
                    appName: $0.appName,
                    inputFieldDescription: $0.inputFieldDescription,
                    isRemoteDesktop: $0.isRemoteDesktop,
                    isIDE: $0.isIDE
                )
            }
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await send(request: request)
        try validateResponse(response, data: data)
        let decoded = try JSONDecoder().decode(RefineResponse.self, from: data)
        let text = normalizeText(decoded.text)
        guard !text.isEmpty else {
            throw CloudDictationError.invalidResponse
        }
        return text
    }

    private func addAuthHeaders(for email: String, to request: inout URLRequest) {
        request.setValue(email, forHTTPHeaderField: "x-voce-email")
        if let token = try? sessionStore.sessionToken(for: email) {
            request.setValue(token, forHTTPHeaderField: "x-voce-session-token")
        }
    }

    private func resolvedSubscriberEmail() throws -> String {
        let email = subscriberEmailProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !email.isEmpty else {
            throw CloudDictationError.authenticationRequired
        }
        let token: String?
        do {
            token = try sessionStore.sessionToken(for: email)
        } catch {
            throw CloudDictationError.authenticationRequired
        }
        guard let token, !token.isEmpty else {
            throw CloudDictationError.authenticationRequired
        }
        return email
    }

    private func send(request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            Self.logger.error("Voce cloud proxy request failed: \(error.localizedDescription, privacy: .public)")
            switch error.code {
            case .timedOut:
                throw CloudDictationError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                throw CloudDictationError.networkUnavailable
            default:
                throw CloudDictationError.providerError(error.localizedDescription)
            }
        } catch {
            Self.logger.error("Voce cloud proxy request failed: \(error.localizedDescription, privacy: .public)")
            throw CloudDictationError.providerError(error.localizedDescription)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudDictationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)

            switch httpResponse.statusCode {
            case 401:
                throw CloudDictationError.authenticationRequired
            case 403:
                throw CloudDictationError.subscriptionRequired
            case 429:
                throw CloudDictationError.rateLimited
            case 500...599:
                throw CloudDictationError.providerError(message)
            default:
                throw CloudDictationError.providerError(message)
            }
        }
    }

    private func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
