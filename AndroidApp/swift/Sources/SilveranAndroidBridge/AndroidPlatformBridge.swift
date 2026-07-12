// Silveran-to-Kotlin platform adapters.
import Foundation
import SilveranKit
import SwiftJava
import Synchronization

@JavaClass("com.kyonifer.silveran.platform.AndroidSecureStore")
open class JavaAndroidSecureStore: JavaObject {}

extension JavaClass<JavaAndroidSecureStore> {
    @JavaStaticMethod
    func store(_ key: String, _ value: String) -> Bool

    @JavaStaticMethod
    func load(_ key: String) -> String

    @JavaStaticMethod
    func remove(_ key: String) -> Bool
}

enum AndroidPlatformBootstrap {
    private static let bootstrappedDirectory = Mutex<URL?>(nil)

    static func bootstrap(filesDirectory: String) throws {
        let directory = URL(fileURLWithPath: filesDirectory, isDirectory: true)
            .standardizedFileURL

        try bootstrappedDirectory.withLock { bootstrappedDirectory in
            if let bootstrappedDirectory {
                guard bootstrappedDirectory == directory else {
                    throw AndroidBridgeError.alreadyBootstrapped(
                        existing: bootstrappedDirectory.path,
                        requested: directory.path,
                    )
                }
                return
            }

            SilveranPlatform.bootstrap(
                keychain: AndroidKeychainStore(),
                applicationStorage: AndroidApplicationStorageProvider(
                    applicationSupportDirectory: directory
                ),
            )
            bootstrappedDirectory = directory
        }
    }

    static var isBootstrapped: Bool {
        bootstrappedDirectory.withLock { $0 != nil }
    }
}

struct AndroidApplicationStorageProvider: ApplicationStorageProviding {
    let applicationSupportDirectory: URL
}

final class AndroidKeychainStore: KeychainStoring, @unchecked Sendable {
    func setItem(_ data: Data, account: String) throws {
        let storage = try JavaClass<JavaAndroidSecureStore>()
        guard storage.store(account, data.base64EncodedString()) else {
            throw AndroidBridgeError.secureStorageFailure(account)
        }
    }

    func item(account: String) throws -> Data? {
        let storage = try JavaClass<JavaAndroidSecureStore>()
        let encoded = storage.load(account)
        guard !encoded.isEmpty else { return nil }
        guard let data = Data(base64Encoded: encoded) else {
            throw KeychainError.invalidData
        }
        return data
    }

    func removeItem(account: String) throws {
        let storage = try JavaClass<JavaAndroidSecureStore>()
        guard storage.remove(account) else {
            throw AndroidBridgeError.secureStorageFailure(account)
        }
    }
}
