// Kotlin-to-Silveran entry points exported through JExtract.
import Foundation
import SilveranKit

public func bootstrapAndroid(filesDirectory: String) throws {
    try AndroidPlatformBootstrap.bootstrap(filesDirectory: filesDirectory)
}

public func storytellerSettingsJSON(requestID: String) async throws {
    try await deliverAndroidBridgePayload(requestID: requestID) {
        try requireAndroidBootstrap()
        return try await encodeStorytellerSettings()
    }
}

public func saveStorytellerSettings(
    requestID: String,
    serverURL: String,
    username: String,
    password: String,
) async throws {
    try await deliverAndroidBridgePayload(requestID: requestID) {
        try await saveStorytellerSettingsJSON(
            serverURL: serverURL,
            username: username,
            password: password,
        )
    }
}

private func saveStorytellerSettingsJSON(
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

public func librarySnapshotJSON(requestID: String, refresh: Bool) async throws {
    try await deliverAndroidBridgePayload(requestID: requestID) {
        try await makeLibrarySnapshotJSON(refresh: refresh)
    }
}

private func makeLibrarySnapshotJSON(refresh: Bool) async throws -> String {
    try requireAndroidBootstrap()

    let snapshot = await BookServiceActor.shared.librarySnapshot(
        policy: refresh ? .refresh : .cachedOnly
    )
    let progress = await ProgressSyncActor.shared.getAllBookProgress()
    let downloads = await DownloadManager.shared.incompleteDownloads
    let downloadsByID = Dictionary(uniqueKeysWithValues: downloads.map { ($0.id, $0) })
    var books: [AndroidBook] = []
    books.reserveCapacity(snapshot.books.count)

    for book in snapshot.books {
        guard let sourceID = book.sourceID else { continue }

        let paths = snapshot.mediaPaths[book.uuid]
        let cachedPaths = snapshot.cachedMediaPaths[book.uuid]
        let media = [
            androidMedia(
                bookID: book.uuid,
                category: .ebook,
                available: book.hasAvailableEbook,
                paths: paths,
                cachedPaths: cachedPaths,
                downloadsByID: downloadsByID,
            ),
            androidMedia(
                bookID: book.uuid,
                category: .audio,
                available: book.hasAvailableAudiobook,
                paths: paths,
                cachedPaths: cachedPaths,
                downloadsByID: downloadsByID,
            ),
            androidMedia(
                bookID: book.uuid,
                category: .synced,
                available: book.hasAvailableReadaloud,
                paths: paths,
                cachedPaths: cachedPaths,
                downloadsByID: downloadsByID,
            ),
        ].compactMap { $0 }

        books.append(
            AndroidBook(
                id: book.uuid,
                sourceID: sourceID,
                title: book.title,
                authors: book.authors?.compactMap(\.name).joined(separator: ", ") ?? "",
                description: book.description.map { BookDescriptionText.plain(from: $0) },
                createdAt: book.createdAt,
                coverVersion: book.updatedAt ?? "",
                media: media,
            )
        )
    }

    let status = connectionFields(await BookServiceActor.shared.connectionStatus)
    let homeSections = HomeSectionDeriver.sections(
        books: snapshot.books,
        progress: progress,
    ).map { section in
        AndroidHomeSection(
            kind: section.kind.rawValue,
            title: section.kind.title,
            bookKeys: section.books.compactMap { book in
                book.sourceID.map { "\($0):\(book.uuid)" }
            },
        )
    }
    return try encodeJSON(
        AndroidLibrary(
            books: books,
            homeSections: homeSections,
            sourceStatus: status.status,
            sourceMessage: status.message,
        )
    )
}

public func coverResponseJSON(
    requestID: String,
    bookID: String,
    sourceID: String,
    version: String,
    audio: Bool,
    width: Int32,
    height: Int32,
    refresh: Bool,
) async throws {
    try await deliverAndroidBridgePayload(requestID: requestID) {
        try await makeCoverResponseJSON(
            bookID: bookID,
            sourceID: sourceID,
            version: version,
            audio: audio,
            width: width,
            height: height,
            refresh: refresh,
        )
    }
}

private func makeCoverResponseJSON(
    bookID: String,
    sourceID: String,
    version: String,
    audio: Bool,
    width: Int32,
    height: Int32,
    refresh: Bool,
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
        policy: refresh ? .forceRefresh : .cachedThenFetch,
    )

    switch response {
        case .cached(let data):
            return try encodeJSON(
                AndroidCoverResponse(
                    dataBase64: data.base64EncodedString(),
                    shouldPersist: false,
                )
            )
        case .fetched(let cover):
            return try encodeJSON(
                AndroidCoverResponse(
                    dataBase64: cover.data.base64EncodedString(),
                    shouldPersist: true,
                )
            )
        case .missing, .skippedOffline:
            return try encodeJSON(
                AndroidCoverResponse(dataBase64: "", shouldPersist: false)
            )
    }
}

public func persistCoverBase64(bookID: String, audio: Bool, dataBase64: String) async throws {
    try requireAndroidBootstrap()
    guard let data = Data(base64Encoded: dataBase64) else {
        throw AndroidBridgeError.invalidCoverData
    }
    await BookServiceActor.shared.persistCachedCover(
        bookID: bookID,
        audio: audio,
        data: data,
    )
}

public func coverSurfaceColorARGB(rgbaBase64: String, dark: Bool) throws -> Int32 {
    guard let data = Data(base64Encoded: rgbaBase64) else {
        throw AndroidBridgeError.invalidCoverPixels
    }
    let color = CoverColorAverager.surfaceColor(rgbaPixels: Array(data), dark: dark)
    let argb = 0xFF00_0000 | UInt32(color.red) << 16 | UInt32(color.green) << 8
        | UInt32(color.blue)
    return Int32(bitPattern: argb)
}

public func downloadBook(
    bookID: String,
    sourceID: String,
    category: String,
) async throws {
    try requireAndroidBootstrap()

    guard let mediaCategory = LocalMediaCategory(rawValue: category) else {
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
    let available = switch mediaCategory {
        case .ebook: book.hasAvailableEbook
        case .audio: book.hasAvailableAudiobook
        case .synced: book.hasAvailableReadaloud
    }
    guard available else {
        throw AndroidBridgeError.mediaUnavailable(category: category, bookID: bookID)
    }

    await DownloadManager.shared.startDownload(for: book, category: mediaCategory)
}

public func cancelBookDownload(bookID: String, category: String) async throws {
    try requireAndroidBootstrap()

    guard let mediaCategory = LocalMediaCategory(rawValue: category) else {
        throw AndroidBridgeError.invalidMediaCategory(category)
    }
    await DownloadManager.shared.cancelDownload(for: bookID, category: mediaCategory)
}

public func deleteBookDownload(
    bookID: String,
    sourceID: String,
    category: String,
) async throws {
    try requireAndroidBootstrap()

    guard let mediaCategory = LocalMediaCategory(rawValue: category) else {
        throw AndroidBridgeError.invalidMediaCategory(category)
    }
    try await BookServiceActor.shared.deleteCachedMedia(
        for: bookID,
        sourceID: sourceID,
        category: mediaCategory,
    )
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
    let createdAt: String?
    let coverVersion: String
    let media: [AndroidMedia]
}

private struct AndroidMedia: Encodable {
    let category: String
    let downloaded: Bool
    let removable: Bool
    let downloadState: String?
    let downloadProgress: Double?
}

private struct AndroidCoverResponse: Encodable {
    let dataBase64: String
    let shouldPersist: Bool
}

private struct AndroidHomeSection: Encodable {
    let kind: String
    let title: String
    let bookKeys: [String]
}

private struct AndroidLibrary: Encodable {
    let books: [AndroidBook]
    let homeSections: [AndroidHomeSection]
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

private func androidMedia(
    bookID: String,
    category: LocalMediaCategory,
    available: Bool,
    paths: MediaPaths?,
    cachedPaths: MediaPaths?,
    downloadsByID: [String: DownloadRecord],
) -> AndroidMedia? {
    guard available else { return nil }
    let record = downloadsByID[downloadID(bookID: bookID, category: category)]
    return AndroidMedia(
        category: category.rawValue,
        downloaded: paths?.path(for: category) != nil,
        removable: cachedPaths?.path(for: category) != nil,
        downloadState: downloadStateName(record?.state),
        downloadProgress: downloadProgress(record),
    )
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
    case invalidCoverData
    case invalidCoverPixels
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
            case .invalidCoverData:
                return "Cover data must be base64 encoded."
            case .invalidCoverPixels:
                return "Cover pixels must be base64-encoded RGBA bytes."
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
