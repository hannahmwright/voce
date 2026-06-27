import Foundation
import VoceKit

struct RealtimeTranscriptionClientSecret: Sendable {
    var value: String
    var expiresAt: Int?
}

struct VoceRealtimeTranscriptionTokenProvider: Sendable {
    private static let cache = RealtimeTranscriptionClientSecretCache()

    private let subscriberEmail: String
    private let sessionStore: VoceAccessSessionStore
    private let session: URLSession
    private let sessionURL: URL

    init(
        subscriberEmail: String,
        sessionStore: VoceAccessSessionStore = .shared,
        session: URLSession = .shared,
        siteBaseURL: URL = VoceCloudSpeechProviderClient.siteBaseURL
    ) {
        self.subscriberEmail = subscriberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sessionStore = sessionStore
        self.session = session
        self.sessionURL = siteBaseURL.appendingPathComponent("cloud-dictation/realtime-session")
    }

    func clientSecret(
        localeIdentifier: String,
        hints: [LexiconEntry],
        model: String
    ) async throws -> String {
        try await clientSecretInfo(
            localeIdentifier: localeIdentifier,
            hints: hints,
            model: model
        ).value
    }

    func clientSecretInfo(
        localeIdentifier: String,
        hints: [LexiconEntry],
        model: String
    ) async throws -> RealtimeTranscriptionClientSecret {
        let key = RealtimeTranscriptionClientSecretCache.Key(
            subscriberEmail: subscriberEmail,
            localeIdentifier: localeIdentifier,
            model: model,
            hints: hints.map(\.preferred)
        )
        let secret = try await Self.cache.clientSecret(for: key) {
            try await requestClientSecret(
                localeIdentifier: localeIdentifier,
                hints: hints,
                model: model
            )
        }
        return RealtimeTranscriptionClientSecret(
            value: secret.value,
            expiresAt: secret.expiresAt
        )
    }

    @discardableResult
    func prefetchClientSecret(
        localeIdentifier: String,
        hints: [LexiconEntry],
        model: String
    ) async throws -> RealtimeTranscriptionClientSecret {
        try await clientSecretInfo(
            localeIdentifier: localeIdentifier,
            hints: hints,
            model: model
        )
    }

    private func requestClientSecret(
        localeIdentifier: String,
        hints: [LexiconEntry],
        model: String
    ) async throws -> RealtimeTranscriptionClientSecretCache.CachedSecret {
        var request = try VoceCloudSpeechProviderClient.authorizedRequest(
            url: sessionURL,
            subscriberEmail: subscriberEmail,
            sessionStore: sessionStore
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            RealtimeSessionRequest(
                localeIdentifier: localeIdentifier,
                hints: hints.map(\.preferred),
                model: model
            )
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudDictationError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw cloudError(status: httpResponse.statusCode, data: data)
            }
            let payload = try JSONDecoder().decode(RealtimeSessionResponse.self, from: data)
            let value = payload.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw CloudDictationError.invalidResponse
            }
            return RealtimeTranscriptionClientSecretCache.CachedSecret(
                value: value,
                expiresAt: payload.expiresAt
            )
        } catch let error as CloudDictationError {
            throw error
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw CloudDictationError.timedOut
            }
            throw CloudDictationError.networkUnavailable
        }
    }

    private func cloudError(status: Int, data: Data) -> CloudDictationError {
        let message = (try? JSONDecoder().decode(RealtimeErrorResponse.self, from: data).error)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401:
            return .authenticationRequired
        case 403:
            if message?.localizedCaseInsensitiveContains("monthly minutes") == true {
                return .hostedCloudMinutesExhausted
            }
            return .subscriptionRequired
        case 408, 504:
            return .timedOut
        case 429:
            return .rateLimited
        default:
            return .providerError(message ?? "Voce realtime dictation is unavailable.")
        }
    }
}

private actor RealtimeTranscriptionClientSecretCache {
    struct Key: Hashable {
        var subscriberEmail: String
        var localeIdentifier: String
        var model: String
        var hints: [String]

        init(
            subscriberEmail: String,
            localeIdentifier: String,
            model: String,
            hints: [String]
        ) {
            self.subscriberEmail = subscriberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.localeIdentifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.hints = hints.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter {
                !$0.isEmpty
            }
        }
    }

    struct CachedSecret: Sendable {
        var value: String
        var expiresAt: Int?

        func isFresh(now: Date, refreshLeadTime: TimeInterval) -> Bool {
            guard let expiresAt else { return false }
            return Date(timeIntervalSince1970: TimeInterval(expiresAt))
                .timeIntervalSince(now) > refreshLeadTime
        }
    }

    private static let refreshLeadTime: TimeInterval = 5 * 60

    private var cachedSecrets: [Key: CachedSecret] = [:]
    private var inFlightRequests: [Key: Task<CachedSecret, Error>] = [:]

    func clientSecret(
        for key: Key,
        fetch: @escaping @Sendable () async throws -> CachedSecret
    ) async throws -> CachedSecret {
        let now = Date()
        if let cached = cachedSecrets[key],
           cached.isFresh(now: now, refreshLeadTime: Self.refreshLeadTime) {
            return cached
        }

        if let existing = inFlightRequests[key] {
            return try await existing.value
        }

        let task = Task {
            try await fetch()
        }
        inFlightRequests[key] = task

        do {
            let secret = try await task.value
            if secret.isFresh(now: Date(), refreshLeadTime: Self.refreshLeadTime) {
                cachedSecrets[key] = secret
            } else {
                cachedSecrets[key] = nil
            }
            inFlightRequests[key] = nil
            return secret
        } catch {
            inFlightRequests[key] = nil
            throw error
        }
    }
}

private struct RealtimeSessionRequest: Encodable {
    var localeIdentifier: String
    var hints: [String]
    var model: String
}

private struct RealtimeSessionResponse: Decodable {
    var clientSecret: String
    var expiresAt: Int?
}

private struct RealtimeErrorResponse: Decodable {
    var error: String
}
