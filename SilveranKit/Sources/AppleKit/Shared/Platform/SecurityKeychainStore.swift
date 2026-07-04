import Foundation

#if canImport(Security)
import Security
#endif

public struct SecurityKeychainStore: KeychainStoring {
    public init() {}

    public func setItem(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
    ) throws {
        #if canImport(Security)
        var query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        // AfterFirstUnlock so background launches (WCSession delivery, background
        // URLSession events) can authenticate while the phone is locked
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status: status)
        }
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    public func item(service: String, account: String, accessGroup: String?) throws -> Data? {
        #if canImport(Security)
        var query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unableToLoad(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        return data
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    public func removeItem(service: String, account: String, accessGroup: String?) throws {
        #if canImport(Security)
        let query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unableToDelete(status: status)
        }
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    #if canImport(Security)
    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?,
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    #endif
}
