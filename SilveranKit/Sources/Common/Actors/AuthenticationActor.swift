import Foundation
import Security

@globalActor
public actor AuthenticationActor {
    public static let shared = AuthenticationActor()

    private let service: String
    private let accessGroup: String
    private let serverURLKey = "serverURL"
    private let usernameKey = "username"
    private let passwordKey = "password"
    private let hardcoverTokenKey = "hardcoverToken"
    private static let serviceInfoKey = "KEYCHAIN_SERVICE"
    private static let accessGroupInfoKey = "KEYCHAIN_ACCESS_GROUP"

    private init() {
        service = Self.requiredInfoValue(for: Self.serviceInfoKey)
        accessGroup = Self.requiredInfoValue(for: Self.accessGroupInfoKey)
    }

    public func saveCredentials(
        url: String,
        username: String,
        password: String,
        sourceID: BookSourceID,
    ) async throws {
        try await deleteCredentials(sourceID: sourceID)

        try saveString(url, for: accountKey(serverURLKey, sourceID: sourceID))
        try saveString(username, for: accountKey(usernameKey, sourceID: sourceID))
        try saveString(password, for: accountKey(passwordKey, sourceID: sourceID))
    }

    public func loadCredentials() async throws -> (url: String, username: String, password: String)?
    {
        guard let url = try loadString(for: serverURLKey),
            let username = try loadString(for: usernameKey),
            let password = try loadString(for: passwordKey)
        else {
            return nil
        }

        return (url, username, password)
    }

    public func loadCredentials(sourceID: BookSourceID) async throws
        -> (url: String, username: String, password: String)?
    {
        guard let url = try loadString(for: accountKey(serverURLKey, sourceID: sourceID)),
            let username = try loadString(for: accountKey(usernameKey, sourceID: sourceID)),
            let password = try loadString(for: accountKey(passwordKey, sourceID: sourceID))
        else {
            return nil
        }

        return (url, username, password)
    }

    public func deleteCredentials() async throws {
        for key in [serverURLKey, usernameKey, passwordKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.unableToDelete(status: status)
            }
        }
    }

    public func deleteCredentials(sourceID: BookSourceID) async throws {
        for key in [serverURLKey, usernameKey, passwordKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: accountKey(key, sourceID: sourceID),
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.unableToDelete(status: status)
            }
        }
    }

    public func hasCredentials(sourceID: BookSourceID) async -> Bool {
        do {
            let creds = try await loadCredentials(sourceID: sourceID)
            return creds != nil
        } catch {
            return false
        }
    }

    // MARK: - Hardcover Token

    public func saveHardcoverToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hardcoverTokenKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        try saveString(token, for: hardcoverTokenKey)
    }

    public func loadHardcoverToken() throws -> String? {
        try loadString(for: hardcoverTokenKey)
    }

    public func deleteHardcoverToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hardcoverTokenKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unableToDelete(status: status)
        }
    }

    private func saveString(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status: status)
        }
    }

    private func loadString(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unableToLoad(status: status)
        }

        guard let data = result as? Data,
            let string = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }

        return string
    }

    private func accountKey(_ key: String, sourceID: BookSourceID) -> String {
        return "bookSource.\(sourceID).\(key)"
    }

    nonisolated private static func infoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func requiredInfoValue(for key: String) -> String {
        guard let value = infoValue(for: key) else {
            preconditionFailure("Missing required Info.plist value for \(key)")
        }
        return value
    }
}

public enum KeychainError: Error, LocalizedError {
    case unableToSave(status: OSStatus)
    case unableToLoad(status: OSStatus)
    case unableToDelete(status: OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
            case .unableToSave(let status):
                return "Unable to save to keychain (status: \(status))"
            case .unableToLoad(let status):
                return "Unable to load from keychain (status: \(status))"
            case .unableToDelete(let status):
                return "Unable to delete from keychain (status: \(status))"
            case .invalidData:
                return "Invalid data in keychain"
        }
    }
}
