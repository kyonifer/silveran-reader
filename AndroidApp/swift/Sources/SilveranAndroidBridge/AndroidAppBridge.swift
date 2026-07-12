// Kotlin-to-Silveran entry points exported through JExtract.
import Foundation
import SilveranKit

public func bootstrapAndroid(filesDirectory: String) throws {
    try AndroidPlatformBootstrap.bootstrap(filesDirectory: filesDirectory)
}

public func storytellerSettingsJSON() async throws -> String {
    try requireAndroidBootstrap()
    return try await encodeStorytellerSettings()
}

public func saveStorytellerSettings(
    serverURL: String,
    username: String,
    password: String,
) async throws -> String {
    try requireAndroidBootstrap()

    let normalizedServerURL = try normalizeServerURL(serverURL)
    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUsername.isEmpty else {
        throw AndroidBridgeError.missingUsername
    }
    let existing = await BookServiceActor.shared.bookSources.first {
        $0.kind == .storyteller
    }
    let resolvedPassword: String
    if !password.isEmpty {
        resolvedPassword = password
    } else if let existing,
        let credentials = await BookServiceActor.shared.credentials(for: existing.id)
    {
        resolvedPassword = credentials.password
    } else {
        throw AndroidBridgeError.missingPassword
    }
    let configuration = BookSourceConfiguration(
        kind: .storyteller,
        name: existing?.name ?? "Storyteller",
        serverURL: normalizedServerURL,
        username: trimmedUsername,
        password: resolvedPassword,
    )

    let saved: Bool
    if let existing {
        saved = await BookServiceActor.shared.updateBookSource(
            id: existing.id,
            configuration: configuration,
        )
    } else {
        saved = await BookServiceActor.shared.createBookSource(configuration) != nil
    }
    guard saved else {
        throw AndroidBridgeError.couldNotSaveStorytellerSettings
    }

    await installAndroidConnectionObserver()
    _ = await BookServiceActor.shared.librarySnapshot(policy: .refresh)
    return try await encodeStorytellerSettings()
}

public func librarySnapshotJSON(refresh: Bool) async throws -> String {
    try requireAndroidBootstrap()

    let snapshot = await BookServiceActor.shared.librarySnapshot(
        policy: refresh ? .refresh : .cachedOnly
    )
    var books: [AndroidBook] = []
    books.reserveCapacity(snapshot.books.count)

    for book in snapshot.books {
        guard let sourceID = book.sourceID else { continue }
        books.append(
            AndroidBook(
                id: book.uuid,
                sourceID: sourceID,
                title: book.title,
                authors: book.authors?.compactMap(\.name).joined(separator: ", ") ?? "",
            )
        )
    }

    let status = connectionFields(await BookServiceActor.shared.connectionStatus)
    return try encodeJSON(
        AndroidLibrary(
            books: books,
            sourceStatus: status.status,
            sourceMessage: status.message,
        )
    )
}

public func startLibraryObservation() async throws {
    try requireAndroidBootstrap()
    guard androidObserverStore.claimInstallation() else { return }

    _ = await BookServiceActor.shared.addLibraryCacheObserver {
        notifyAndroidLibrarySnapshotDidChange()
    }
    await installAndroidConnectionObserver()
}

private struct AndroidBook: Encodable {
    let id: String
    let sourceID: String
    let title: String
    let authors: String
}

private struct AndroidLibrary: Encodable {
    let books: [AndroidBook]
    let sourceStatus: String
    let sourceMessage: String?
}

private struct AndroidStorytellerSettings: Encodable {
    let configured: Bool
    let sourceID: String?
    let serverURL: String?
    let username: String?
    let connectionStatus: String
    let connectionMessage: String?
}

private final class AndroidObserverStore: @unchecked Sendable {
    private let lock = NSLock()
    private var observersInstalled = false

    func claimInstallation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !observersInstalled else { return false }
        observersInstalled = true
        return true
    }
}

private let androidObserverStore = AndroidObserverStore()

private func installAndroidConnectionObserver() async {
    await BookServiceActor.shared.request_notify {
        notifyAndroidLibrarySnapshotDidChange()
    }
}

private func encodeStorytellerSettings() async throws -> String {
    let source = await BookServiceActor.shared.bookSources.first {
        $0.kind == .storyteller
    }
    let credentials: (url: String, username: String, password: String)?
    let connection: ConnectionStatus

    if let source {
        credentials = await BookServiceActor.shared.credentials(for: source.id)
        connection = await BookServiceActor.shared.connectionStatus(sourceID: source.id)
    } else {
        credentials = nil
        connection = .disconnected
    }

    let status = connectionFields(connection)
    return try encodeJSON(
        AndroidStorytellerSettings(
            configured: source != nil && credentials != nil,
            sourceID: source?.id,
            serverURL: credentials?.url,
            username: credentials?.username,
            connectionStatus: status.status,
            connectionMessage: status.message,
        )
    )
}

private func requireAndroidBootstrap() throws {
    guard AndroidPlatformBootstrap.isBootstrapped else {
        throw AndroidBridgeError.notBootstrapped
    }
}

private func normalizeServerURL(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AndroidBridgeError.invalidServerURL(value)
    }
    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: normalized),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        url.host != nil
    else {
        throw AndroidBridgeError.invalidServerURL(value)
    }
    return normalized
}

private func connectionFields(_ connection: ConnectionStatus) -> (
    status: String,
    message: String?
) {
    switch connection {
        case .disconnected:
            return ("disconnected", nil)
        case .connecting:
            return ("connecting", nil)
        case .connected:
            return ("connected", nil)
        case .error(let message):
            return ("error", message)
    }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

enum AndroidBridgeError: Error, LocalizedError, CustomStringConvertible {
    case notBootstrapped
    case alreadyBootstrapped(existing: String, requested: String)
    case invalidServerURL(String)
    case missingUsername
    case missingPassword
    case couldNotSaveStorytellerSettings
    case secureStorageFailure(String)

    var errorDescription: String? {
        switch self {
            case .notBootstrapped:
                return "Silveran's Android platform has not been bootstrapped."
            case .alreadyBootstrapped(let existing, let requested):
                return "Silveran was already bootstrapped with \(existing), not \(requested)."
            case .invalidServerURL(let value):
                return "Invalid Storyteller server URL: \(value)"
            case .missingUsername:
                return "A Storyteller username is required."
            case .missingPassword:
                return "A Storyteller password is required."
            case .couldNotSaveStorytellerSettings:
                return "Could not save the Storyteller server settings."
            case .secureStorageFailure(let account):
                return "Android secure storage failed for account \(account)."
        }
    }

    var description: String {
        errorDescription ?? "Android bridge error"
    }
}
