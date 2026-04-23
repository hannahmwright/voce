import Foundation
import Security
import VoceKit

enum CloudProviderCredentialStoreError: LocalizedError {
    case missingAPIKey
    case invalidAPIKeySource
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key missing."
        case .invalidAPIKeySource:
            return "Cloud dictation API key source is invalid."
        case .keychain:
            return "Could not access the cloud dictation API key."
        }
    }
}

final class CloudProviderCredentialStore: @unchecked Sendable {
    static let shared = CloudProviderCredentialStore()

    private let service = "\(VoceRuntimeConfiguration.bundleIdentifier).cloud-dictation.openai-api-key.v1"
    private let account = "default"
    private let environmentVariableName = "OPENAI_API_KEY"

    func saveOpenAIAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearOpenAIAPIKey()
            return
        }

        let data = Data(trimmed.utf8)
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
            throw CloudProviderCredentialStoreError.keychain(status: status)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudProviderCredentialStoreError.keychain(status: addStatus)
        }
    }

    func clearOpenAIAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudProviderCredentialStoreError.keychain(status: status)
        }
    }

    func hasStoredOpenAIAPIKey() -> Bool {
        (try? storedOpenAIAPIKey())?.isEmpty == false
    }

    func resolveOpenAIAPIKey(source: CloudAPIKeySource) throws -> String {
        switch source {
        case .keychain:
            guard let key = try storedOpenAIAPIKey(), !key.isEmpty else {
                throw CloudProviderCredentialStoreError.missingAPIKey
            }
            return key
        case .environment:
            let key = ProcessInfo.processInfo.environment[environmentVariableName]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                throw CloudProviderCredentialStoreError.missingAPIKey
            }
            return key
        }
    }

    func environmentVariableDisplayName() -> String {
        environmentVariableName
    }

    private func storedOpenAIAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess else {
            throw CloudProviderCredentialStoreError.keychain(status: status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
