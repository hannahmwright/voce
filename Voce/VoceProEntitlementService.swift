import Foundation
import Security

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
    case needsVerification(email: String)
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
        case .needsVerification:
            return "Verify your email to check Voce access."
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
                return "Voce Pro is active.\nVoce loves you. Pro is on us!"
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
    case authenticationRequired
    case invalidEmail
    case accessCodeUnavailable
    case invalidResponse
    case server(status: Int)
    case portalUnavailable
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Verify your email to check Voce access."
        case .invalidEmail:
            return "Enter a valid email address."
        case .accessCodeUnavailable:
            return "Could not send an access code."
        case .invalidResponse:
            return "Could not read Voce access."
        case .server:
            return "Could not check Voce access."
        case .portalUnavailable:
            return "Could not open subscription settings."
        case .verificationFailed:
            return "Could not verify that code."
        }
    }
}

struct VoceAccessVerificationSession: Decodable, Equatable, Sendable {
    var email: String
    var sessionToken: String
    var expiresAt: Double
}

actor VoceProEntitlementService {
    static let defaultFeature = "voce_app_access"
    static let checkoutURL = URL(string: "https://buy.stripe.com/00w00j2TP7ae5cL7nta3u00")!
    #if DEBUG
    private static let siteBaseURL = URL(string: "https://cheerful-raven-194.convex.site")!
    #else
    private static let siteBaseURL = URL(string: "https://combative-ant-133.convex.site")!
    #endif

    private let authStartURL: URL
    private let authVerifyURL: URL
    private let endpointURL: URL
    private let usageEndpointURL: URL
    private let portalEndpointURL: URL
    private let feature: String
    private let apiSecret: String?
    private let session: URLSession
    private let sessionStore: VoceAccessSessionStore

    init(
        authStartURL: URL = siteBaseURL.appendingPathComponent("auth/start"),
        authVerifyURL: URL = siteBaseURL.appendingPathComponent("auth/verify"),
        endpointURL: URL = siteBaseURL.appendingPathComponent("entitlements/check"),
        usageEndpointURL: URL = siteBaseURL.appendingPathComponent("entitlements/record-usage"),
        portalEndpointURL: URL = siteBaseURL.appendingPathComponent("stripe/portal"),
        feature: String = VoceProEntitlementService.defaultFeature,
        apiSecret: String? = nil,
        session: URLSession = .shared,
        sessionStore: VoceAccessSessionStore = .shared
    ) {
        self.authStartURL = authStartURL
        self.authVerifyURL = authVerifyURL
        self.endpointURL = endpointURL
        self.usageEndpointURL = usageEndpointURL
        self.portalEndpointURL = portalEndpointURL
        self.feature = feature
        self.apiSecret = apiSecret
        self.session = session
        self.sessionStore = sessionStore
    }

    func requestVerificationCode(email: String) async throws {
        var request = URLRequest(url: authStartURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(AuthStartRequest(email: email))

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        if httpResponse.statusCode == 400 {
            throw VoceProEntitlementError.invalidEmail
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoceProEntitlementError.accessCodeUnavailable
        }
    }

    func verifyCode(email: String, code: String) async throws -> VoceAccessVerificationSession {
        var request = URLRequest(url: authVerifyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(AuthVerifyRequest(email: email, code: code))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoceProEntitlementError.verificationFailed
        }
        let verifiedSession = try JSONDecoder().decode(VoceAccessVerificationSession.self, from: data)
        try sessionStore.save(sessionToken: verifiedSession.sessionToken, email: verifiedSession.email)
        return verifiedSession
    }

    #if DEBUG
    func clearSession(email: String) throws {
        try sessionStore.deleteSession(email: email)
    }
    #endif

    func check(email: String) async throws -> VoceProEntitlement {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        addSessionToken(for: email, to: &request)
        if let apiSecret, !apiSecret.isEmpty {
            request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(CheckRequest(email: email, feature: feature))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw VoceProEntitlementError.authenticationRequired
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
        addSessionToken(for: email, to: &request)
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
        if httpResponse.statusCode == 401 {
            throw VoceProEntitlementError.authenticationRequired
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
        addSessionToken(for: email, to: &request)
        if let apiSecret, !apiSecret.isEmpty {
            request.setValue("Bearer \(apiSecret)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(PortalSessionRequest(email: email))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoceProEntitlementError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw VoceProEntitlementError.authenticationRequired
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

    private func addSessionToken(for email: String, to request: inout URLRequest) {
        guard let token = try? sessionStore.sessionToken(for: email) else { return }
        request.setValue(token, forHTTPHeaderField: "x-voce-session-token")
    }
}

final class VoceAccessSessionStore: @unchecked Sendable {
    static let shared = VoceAccessSessionStore()

    private let service = "io.voceapp.voce.access-session"

    func save(sessionToken: String, email: String) throws {
        let account = normalizedEmail(email)
        let data = Data(sessionToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw VoceAccessSessionStoreError.keychain(status: status)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VoceAccessSessionStoreError.keychain(status: addStatus)
        }
    }

    func sessionToken(for email: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedEmail(email),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw VoceAccessSessionStoreError.keychain(status: status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func deleteSession(email: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedEmail(email),
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoceAccessSessionStoreError.keychain(status: status)
        }
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum VoceAccessSessionStoreError: LocalizedError {
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "Could not save Voce access on this Mac."
        }
    }
}

private struct AuthStartRequest: Encodable {
    var email: String
}

private struct AuthVerifyRequest: Encodable {
    var email: String
    var code: String
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
