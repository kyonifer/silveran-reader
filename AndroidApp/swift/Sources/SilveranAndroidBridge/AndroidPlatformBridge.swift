// Silveran-to-Kotlin platform adapters and callbacks.
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

@JavaClass("com.kyonifer.silveran.bridge.AndroidBridgeCallbacks")
open class JavaAndroidBridgeCallbacks: JavaObject {}

extension JavaClass<JavaAndroidBridgeCallbacks> {
    @JavaStaticMethod
    func librarySnapshotDidChange()

    @JavaStaticMethod
    func bridgeRequestDidComplete(_ requestID: String, _ payload: String, _ error: String)
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
                audioPlayerFactory: AndroidAudioPlayerFactory(),
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

func notifyAndroidLibrarySnapshotDidChange() {
    try? JavaClass<JavaAndroidBridgeCallbacks>().librarySnapshotDidChange()
}

func deliverAndroidBridgePayload(
    requestID: String,
    operation: () async throws -> String,
) async throws {
    // swift-java 0.4.2 retains async String refs; upcalls release them in a local frame.
    let payload: String
    do {
        payload = try await operation()
    } catch {
        try JavaClass<JavaAndroidBridgeCallbacks>().bridgeRequestDidComplete(
            requestID,
            "",
            String(describing: error),
        )
        return
    }
    try JavaClass<JavaAndroidBridgeCallbacks>().bridgeRequestDidComplete(requestID, payload, "")
}
