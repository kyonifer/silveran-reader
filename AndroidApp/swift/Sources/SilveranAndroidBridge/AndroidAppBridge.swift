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
    let downloads = await DownloadManager.shared.incompleteDownloads
    let downloadsByID = Dictionary(uniqueKeysWithValues: downloads.map { ($0.id, $0) })
    var books: [AndroidBook] = []
    books.reserveCapacity(snapshot.books.count)

    for book in snapshot.books {
        guard let sourceID = book.sourceID else { continue }

        let ebookDownloadRecord = downloadsByID[
            downloadID(bookID: book.uuid, category: .ebook)
        ]
        let audioCategory: LocalMediaCategory =
            book.hasAvailableAudiobook ? .audio : .synced
        let audioDownloadRecord = downloadsByID[
            downloadID(bookID: book.uuid, category: audioCategory)
        ]
        let paths = snapshot.mediaPaths[book.uuid]

        books.append(
            AndroidBook(
                id: book.uuid,
                sourceID: sourceID,
                title: book.title,
                authors: book.authors?.compactMap(\.name).joined(separator: ", ") ?? "",
                description: book.description,
                coverVersion: book.updatedAt ?? "",
                hasEbook: book.hasAvailableEbook,
                hasAudio: book.hasAnyAudiobookAsset,
                ebookDownloaded: paths?.ebookPath != nil,
                audioDownloaded: paths?.audioPath != nil || paths?.syncedPath != nil,
                ebookDownloadState: downloadStateName(ebookDownloadRecord?.state),
                audioDownloadState: downloadStateName(audioDownloadRecord?.state),
                ebookDownloadProgress: downloadProgress(ebookDownloadRecord),
                audioDownloadProgress: downloadProgress(audioDownloadRecord),
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

public func coverBase64(
    bookID: String,
    sourceID: String,
    version: String,
    audio: Bool,
    width: Int32,
    height: Int32,
) async throws -> String {
    try requireAndroidBootstrap()
    guard width > 0, height > 0 else {
        throw AndroidBridgeError.invalidCoverSize
    }

    let response = await BookServiceActor.shared.loadCover(
        for: bookID,
        sourceID: sourceID,
        audio: audio,
        width: Int(width),
        height: Int(height),
        version: version.isEmpty ? nil : version,
        allowNetwork: true,
        policy: .forceRefresh,
    )

    switch response {
        case .cached(let data):
            return data.base64EncodedString()
        case .fetched(let cover):
            return cover.data.base64EncodedString()
        case .missing, .skippedOffline:
            return ""
    }
}

public func downloadBook(
    bookID: String,
    sourceID: String,
    category: String,
) async throws {
    try requireAndroidBootstrap()

    guard
        category == LocalMediaCategory.ebook.rawValue
            || category == LocalMediaCategory.audio.rawValue
    else {
        throw AndroidBridgeError.invalidMediaCategory(category)
    }

    let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
    guard
        let book = snapshot.books.first(where: {
            $0.uuid == bookID && $0.sourceID == sourceID
        })
    else {
        throw AndroidBridgeError.bookNotFound(bookID)
    }
    let mediaCategory: LocalMediaCategory
    if category == LocalMediaCategory.ebook.rawValue {
        mediaCategory = .ebook
    } else if book.hasAvailableAudiobook {
        mediaCategory = .audio
    } else {
        mediaCategory = .synced
    }
    guard mediaCategory == .ebook ? book.hasAvailableEbook : book.hasAnyAudiobookAsset else {
        throw AndroidBridgeError.mediaUnavailable(category: category, bookID: bookID)
    }

    await DownloadManager.shared.startDownload(for: book, category: mediaCategory)
}

public func cancelBookDownload(bookID: String, category: String) async throws {
    try requireAndroidBootstrap()

    switch category {
        case LocalMediaCategory.ebook.rawValue:
            await DownloadManager.shared.cancelDownload(for: bookID, category: .ebook)
        case LocalMediaCategory.audio.rawValue:
            // The Android "audio" action also represents readaloud media.
            await DownloadManager.shared.cancelDownload(for: bookID, category: .audio)
            await DownloadManager.shared.cancelDownload(for: bookID, category: .synced)
        default:
            throw AndroidBridgeError.invalidMediaCategory(category)
    }
}

public func startLibraryObservation() async throws {
    try requireAndroidBootstrap()
    guard androidObserverStore.claimInstallation() else { return }

    _ = await BookServiceActor.shared.addLibraryCacheObserver {
        notifyAndroidLibrarySnapshotDidChange()
    }
    _ = await DownloadManager.shared.addObserver { _ in
        notifyAndroidLibrarySnapshotDidChange()
    }
    await installAndroidConnectionObserver()
}

private struct AndroidBook: Encodable {
    let id: String
    let sourceID: String
    let title: String
    let authors: String
    let description: String?
    let coverVersion: String
    let hasEbook: Bool
    let hasAudio: Bool
    let ebookDownloaded: Bool
    let audioDownloaded: Bool
    let ebookDownloadState: String?
    let audioDownloadState: String?
    let ebookDownloadProgress: Double?
    let audioDownloadProgress: Double?
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

private func downloadStateName(_ state: DownloadState?) -> String? {
    switch state {
        case .queued: return "queued"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .failed: return "failed"
        case .importing: return "importing"
        case .completed: return "completed"
        case nil: return nil
    }
}

private func downloadProgress(_ record: DownloadRecord?) -> Double? {
    guard let record, record.isActive else { return nil }
    return record.progressFraction
}

private func downloadID(bookID: String, category: LocalMediaCategory) -> String {
    "\(bookID)-\(category.rawValue)"
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
    case invalidCoverSize
    case invalidMediaCategory(String)
    case bookNotFound(String)
    case mediaUnavailable(category: String, bookID: String)
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
            case .invalidCoverSize:
                return "Cover width and height must be greater than zero."
            case .invalidMediaCategory(let category):
                return "Unsupported media category: \(category)"
            case .bookNotFound(let bookID):
                return "Book \(bookID) is no longer in the library."
            case .mediaUnavailable(let category, let bookID):
                return "Book \(bookID) has no \(category) available to download."
            case .secureStorageFailure(let account):
                return "Android secure storage failed for account \(account)."
        }
    }

    var description: String {
        errorDescription ?? "Android bridge error"
    }
}
