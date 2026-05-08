import Foundation
import OSLog
import VoceKit

struct VoceCloudSpeechProviderClient: CloudSpeechProviderClient {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "VoceCloudSpeech")

    #if DEBUG
    static let siteBaseURL = URL(string: "https://cheerful-raven-194.convex.site")!
    #else
    static let siteBaseURL = URL(string: "https://combative-ant-133.convex.site")!
    #endif

    private let subscriberEmail: String
    private let sessionStore: VoceAccessSessionStore
    private let session: URLSession
    private let preflightURL: URL
    private let transcribeURL: URL
    private let refineURL: URL

    init(
        subscriberEmail: String,
        sessionStore: VoceAccessSessionStore = .shared,
        session: URLSession = .shared,
        siteBaseURL: URL = Self.siteBaseURL
    ) {
        self.subscriberEmail = subscriberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sessionStore = sessionStore
        self.session = session
        self.preflightURL = siteBaseURL.appendingPathComponent("cloud-dictation/preflight")
        self.transcribeURL = siteBaseURL.appendingPathComponent("cloud-dictation/transcribe")
        self.refineURL = siteBaseURL.appendingPathComponent("cloud-dictation/refine")
    }

    static func authorizedRequest(
        url: URL,
        subscriberEmail: String,
        sessionStore: VoceAccessSessionStore = .shared
    ) throws -> URLRequest {
        let email = subscriberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else {
            throw CloudDictationError.authenticationRequired
        }
        guard let token = try sessionStore.sessionToken(for: email)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw CloudDictationError.authenticationRequired
        }

        var request = URLRequest(url: url)
        request.setValue(email, forHTTPHeaderField: "x-voce-email")
        request.setValue(token, forHTTPHeaderField: "x-voce-session-token")
        request.setValue("Voce macOS", forHTTPHeaderField: "user-agent")
        return request
    }

    func preflightCheck(localeIdentifier: String) async throws {
        let body = try JSONEncoder().encode(PreflightRequest(localeIdentifier: localeIdentifier))
        var request = try authorizedRequest(url: preflightURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        _ = try await send(request: request, timeoutError: .timedOut)
    }

    func transcribe(audioURL: URL, localeIdentifier: String, hints: [String]) async throws -> RawTranscript {
        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else {
            throw CloudDictationError.invalidAudioFile
        }

        let boundary = "VoceBoundary-\(UUID().uuidString)"
        var request = try authorizedRequest(url: transcribeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = try multipartBody(
            boundary: boundary,
            fields: [
                "localeIdentifier": localeIdentifier,
                "hints": String(data: JSONEncoder().encode(hints), encoding: .utf8) ?? "[]"
            ],
            file: MultipartFile(
                fieldName: "file",
                filename: audioURL.lastPathComponent.isEmpty ? "voce-audio.wav" : audioURL.lastPathComponent,
                contentType: contentType(for: audioURL),
                data: audioData
            )
        )

        let data = try await send(request: request, timeoutError: .timedOut)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudDictationError.emptyTranscript
        }

        Self.logger.notice("Voce cloud transcription completed with \(text.count, privacy: .public) characters")
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
        let body = try JSONEncoder().encode(
            RefineRequest(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                dictionary: dictionary.map(SerializedLexiconEntry.init),
                profile: SerializedStyleProfile(profile),
                appContext: appContext.map(SerializedAppContext.init)
            )
        )
        var request = try authorizedRequest(url: refineURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        let data = try await send(request: request, timeoutError: .timedOut)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudDictationError.invalidResponse
        }
        return text
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        try Self.authorizedRequest(
            url: url,
            subscriberEmail: subscriberEmail,
            sessionStore: sessionStore
        )
    }

    private func send(request: URLRequest, timeoutError: CloudDictationError) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudDictationError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw cloudError(status: httpResponse.statusCode, data: data)
            }
            return data
        } catch let error as CloudDictationError {
            throw error
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw timeoutError
            }
            throw CloudDictationError.networkUnavailable
        }
    }

    private func cloudError(status: Int, data: Data) -> CloudDictationError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401:
            return .authenticationRequired
        case 403:
            return .subscriptionRequired
        case 408, 504:
            return .timedOut
        case 429:
            return .rateLimited
        case 400:
            return .providerError(message ?? "Cloud dictation request was rejected.")
        default:
            return .providerError(message ?? "Voce cloud dictation is unavailable.")
        }
    }

    private func multipartBody(
        boundary: String,
        fields: [String: String],
        file: MultipartFile
    ) throws -> Data {
        var data = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields {
            data.appendString("--\(boundary)\(lineBreak)")
            data.appendString("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            data.appendString(value)
            data.appendString(lineBreak)
        }

        data.appendString("--\(boundary)\(lineBreak)")
        data.appendString(
            "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\(lineBreak)"
        )
        data.appendString("Content-Type: \(file.contentType)\(lineBreak)\(lineBreak)")
        data.append(file.data)
        data.appendString(lineBreak)
        data.appendString("--\(boundary)--\(lineBreak)")
        return data
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }
}

private struct PreflightRequest: Encodable {
    var localeIdentifier: String
}

private struct TranscriptionResponse: Decodable {
    var text: String
}

private struct ErrorResponse: Decodable {
    var error: String
}

private struct RefineRequest: Encodable {
    var transcript: String
    var localeIdentifier: String
    var dictionary: [SerializedLexiconEntry]
    var profile: SerializedStyleProfile
    var appContext: SerializedAppContext?
}

private struct SerializedLexiconEntry: Encodable {
    var term: String
    var preferred: String
    var scope: String
    var bundleIdentifier: String?

    init(_ entry: LexiconEntry) {
        self.term = entry.term
        self.preferred = entry.preferred
        switch entry.scope {
        case .global:
            self.scope = "global"
            self.bundleIdentifier = nil
        case .app(let bundleID):
            self.scope = "app"
            self.bundleIdentifier = bundleID
        }
    }
}

private struct SerializedStyleProfile: Encodable {
    var tone: String
    var structureMode: String
    var fillerPolicy: String
    var commandPolicy: String

    init(_ profile: StyleProfile) {
        self.tone = profile.tone.rawValue
        self.structureMode = profile.structureMode.rawValue
        self.fillerPolicy = profile.fillerPolicy.rawValue
        self.commandPolicy = profile.commandPolicy.rawValue
    }
}

private struct SerializedAppContext: Encodable {
    var bundleIdentifier: String
    var appName: String
    var inputFieldDescription: String?
    var isRemoteDesktop: Bool
    var isIDE: Bool

    init(_ appContext: AppContext) {
        self.bundleIdentifier = appContext.bundleIdentifier
        self.appName = appContext.appName
        self.inputFieldDescription = appContext.inputFieldDescription
        self.isRemoteDesktop = appContext.isRemoteDesktop
        self.isIDE = appContext.isIDE
    }
}

private struct MultipartFile {
    var fieldName: String
    var filename: String
    var contentType: String
    var data: Data
}
