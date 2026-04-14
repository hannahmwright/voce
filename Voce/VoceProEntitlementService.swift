import Foundation

struct VoceProEntitlement: Decodable, Equatable, Sendable {
    var email: String
    var entitled: Bool
    var expiresAt: Double?
    var feature: String
    var source: Source?
    var freeLimitSeconds: Int?
    var freeUsedSeconds: Int?
    var freeRemainingSeconds: Int?
    var periodStartsAt: Double?
    var periodEndsAt: Double?

    enum Source: String, Decodable, Sendable {
        case free
        case manual
        case stripe
    }

    var freeRemainingMinutesText: String? {
        guard let freeRemainingSeconds else { return nil }
        let minutes = max(0, Int(ceil(Double(freeRemainingSeconds) / 60)))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    var freeRecordingRemainingSeconds: TimeInterval? {
        guard source == .free, entitled, let freeRemainingSeconds else { return nil }
        return TimeInterval(freeRemainingSeconds)
    }
}

enum VoceProEntitlementStatus: Equatable {
    case missingEmail
    case checking(email: String)
    case entitled(VoceProEntitlement)
    case notEntitled(email: String)
    case failed(email: String, message: String)

    var isEntitled: Bool {
        if case .entitled = self {
            return true
        }
        return false
    }

    var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }

    var freeRecordingRemainingSeconds: TimeInterval? {
        guard case .entitled(let entitlement) = self else { return nil }
        return entitlement.freeRecordingRemainingSeconds
    }

    var message: String {
        switch self {
        case .missingEmail:
            return "Enter an email to start with free monthly Voce access."
        case .checking:
            return "Checking Voce access..."
        case .entitled(let entitlement):
            switch entitlement.source {
            case .free:
                if let remaining = entitlement.freeRemainingMinutesText {
                    return "Free access active. \(remaining) left this month."
                }
                return "Free access is active."
            case .manual:
                return "Voce Pro is active.\nVoce ❤️'s you. Pro is on us!"
            case .stripe:
                return "Voce Pro is active."
            case nil:
                return "Voce access is active."
            }
        case .notEntitled:
            return "Monthly free time is used. Subscribe to keep using Voce."
        case .failed(_, let message):
            return message
        }
    }
}

enum VoceProEntitlementError: LocalizedError {
    case invalidResponse
    case server(status: Int)
    case portalUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Could not read Voce access."
        case .server:
            return "Could not check Voce access."
        case .portalUnavailable:
            return "Could not open subscription settings."
        }
    }
}

actor VoceProEntitlementService {
    static let defaultFeature = "voce_app_access"
    static let checkoutURL = URL(string: "https://buy.stripe.com/00w00j2TP7ae5cL7nta3u00")!

    private let endpointURL: URL
    private let usageEndpointURL: URL
    private let portalEndpointURL: URL
    private let feature: String
    private let apiSecret: String?
    private let session: URLSession

    init(
        endpointURL: URL = URL(string: "https://combative-ant-133.convex.site/entitlements/check")!,
        usageEndpointURL: URL = URL(string: "https://combative-ant-133.convex.site/entitlements/record-usage")!,
        portalEndpointURL: URL = URL(string: "https://combative-ant-133.convex.site/stripe/portal")!,
        feature: String = VoceProEntitlementService.defaultFeature,
        apiSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.usageEndpointURL = usageEndpointURL
        self.portalEndpointURL = portalEndpointURL
        self.feature = feature
        self.apiSecret = apiSecret
        self.session = session
    }

    func check(email: String) async throws -> VoceProEntitlement {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiSecret, !apiSecret.isEmpty {
            request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(CheckRequest(email: email, feature: feature))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoceProEntitlementError.server(status: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(VoceProEntitlement.self, from: data)
    }

    func recordUsage(email: String, seconds: Int) async throws -> VoceProEntitlement {
        var request = URLRequest(url: usageEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiSecret, !apiSecret.isEmpty {
            request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            RecordUsageRequest(email: email, feature: feature, seconds: seconds)
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoceProEntitlementError.server(status: httpResponse.statusCode)
        }
        return try JSONDecoder().decode(VoceProEntitlement.self, from: data)
    }

    func portalURL(email: String) async throws -> URL {
        var request = URLRequest(url: portalEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiSecret, !apiSecret.isEmpty {
            request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(PortalSessionRequest(email: email))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoceProEntitlementError.portalUnavailable
        }
        let portalSession = try JSONDecoder().decode(PortalSessionResponse.self, from: data)
        guard let url = URL(string: portalSession.url) else {
            throw VoceProEntitlementError.invalidResponse
        }
        return url
    }
}

private struct CheckRequest: Encodable {
    var email: String
    var feature: String
}

private struct RecordUsageRequest: Encodable {
    var email: String
    var feature: String
    var seconds: Int
}

private struct PortalSessionRequest: Encodable {
    var email: String
}

private struct PortalSessionResponse: Decodable {
    var url: String
}
