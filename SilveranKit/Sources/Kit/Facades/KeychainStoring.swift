import Foundation

/// Generic secure item store. Domain logic (which services/accounts exist,
/// payload encoding) stays in AuthenticationActor; this is only the vault.
public protocol KeychainStoring: Sendable {
    func setItem(_ data: Data, service: String, account: String, accessGroup: String?) async throws
    func item(service: String, account: String, accessGroup: String?) async throws -> Data?
    func removeItem(service: String, account: String, accessGroup: String?) async throws
}
