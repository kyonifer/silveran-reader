import Foundation
import Security

@globalActor
public actor AuthenticationActor {
    public static let shared = AuthenticationActor()

    private let service = "com.kyonifer.silveran.storyteller"
    private let serverURLKey = "serverURL"
    private let usernameKey = "username"
    private let passwordKey = "password"

    private init() {}

    public func saveCredentials(url: String, username: String, password: String) async throws {
        try await deleteCredentials()

        try saveString(url, for: serverURLKey)
        try saveString(username, for: usernameKey)
        try saveString(password, for: passwordKey)
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

    public func deleteCredentials() async throws {
        for key in [serverURLKey, usernameKey, passwordKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.unableToDelete(status: status)
            }
        }
    }

    public func hasCredentials() async -> Bool {
        do {
            let creds = try await loadCredentials()
            return creds != nil
        } catch {
            return false
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
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
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
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
