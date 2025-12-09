import Foundation

public struct MediaPaths: Sendable {
    public var ebookPath: URL?
    public var audioPath: URL?
    public var syncedPath: URL?

    public init(ebookPath: URL? = nil, audioPath: URL? = nil, syncedPath: URL? = nil) {
        self.ebookPath = ebookPath
        self.audioPath = audioPath
        self.syncedPath = syncedPath
    }
}

public enum LocalMediaImportEvent: Sendable {
    case started(book: BookMetadata, category: LocalMediaCategory, expectedBytes: Int64?)
    case progress(
        book: BookMetadata,
        category: LocalMediaCategory,
        receivedBytes: Int64,
        expectedBytes: Int64?
    )
    case finished(book: BookMetadata, category: LocalMediaCategory, destination: URL)
    case skipped(book: BookMetadata, category: LocalMediaCategory)
}

@globalActor
public actor LocalMediaActor: GlobalActor {
    public static let shared = LocalMediaActor()
    private(set) public var localStandaloneMetadata: [BookMetadata] = []
    private(set) public var localStorytellerMetadata: [BookMetadata] = []
    private(set) public var localStorytellerBookPaths: [String: MediaPaths] = [:]
    private(set) public var localStandaloneBookPaths: [String: MediaPaths] = [:]
    private let filesystem: FilesystemActor
    private let localLibrary: LocalLibraryManager
    private var periodicScanTask: Task<Void, Never>?

    private static let extensionCategoryMap: [String: LocalMediaCategory] = [
        "epub": .ebook,
        "m4b": .audio,
    ]

    public static var allowedExtensions: [String] {
        Array(extensionCategoryMap.keys).sorted()
    }

    private var viewModelUpdateCallback: (@Sendable () -> Void)?

    public init(
        viewModelUpdateCallback: (@Sendable () -> Void)? = nil,
        filesystem: FilesystemActor = .shared,
        localLibrary: LocalLibraryManager = LocalLibraryManager()
    ) {
        self.viewModelUpdateCallback = viewModelUpdateCallback
        self.filesystem = filesystem
        self.localLibrary = localLibrary
        Task { [weak self] in
            try? await filesystem.ensureLocalStorageDirectories()
            try? await self?.scanForMedia()
            await self?.startPeriodicScan()
        }
    }

    private func startPeriodicScan() {
        periodicScanTask?.cancel()
        periodicScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { break }
                try? await self?.scanForMedia()
            }
        }
    }

    public func setViewModelUpdateCallback(_ callback: @escaping @Sendable () -> Void) {
        viewModelUpdateCallback = callback
    }

    public func updateStorytellerMetadata(_ metadata: [BookMetadata]) async throws {
        let mergedMetadata = mergeWithLocalTimestamps(metadata)
        let pendingSyncs = await ProgressSyncActor.shared.getPendingProgressSyncs()
        let enrichedMetadata = applyOfflineProgressToMetadata(mergedMetadata, pendingSyncs: pendingSyncs)
        localStorytellerMetadata = enrichedMetadata

        try await filesystem.saveStorytellerLibraryMetadata(metadata)

        var paths: [String: MediaPaths] = [:]
        for book in enrichedMetadata {
            let mediaPaths = await scanBookPaths(for: book.uuid, domain: .storyteller)
            paths[book.uuid] = mediaPaths
        }
        localStorytellerBookPaths = paths

        viewModelUpdateCallback?()
    }

    public func updateBookProgress(bookId: String, locator: BookLocator, timestamp: Double) async {
        debugLog("[LocalMediaActor] updateBookProgress: bookId=\(bookId)")

        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()

        if let index = localStorytellerMetadata.firstIndex(where: { $0.uuid == bookId }) {
            var updatedMetadata = localStorytellerMetadata[index]
            let newPosition = BookReadingPosition(
                uuid: updatedMetadata.position?.uuid,
                locator: locator,
                timestamp: timestamp,
                createdAt: updatedMetadata.position?.createdAt,
                updatedAt: updatedAtString
            )
            updatedMetadata = BookMetadata(
                uuid: updatedMetadata.uuid,
                title: updatedMetadata.title,
                subtitle: updatedMetadata.subtitle,
                description: updatedMetadata.description,
                language: updatedMetadata.language,
                createdAt: updatedMetadata.createdAt,
                updatedAt: updatedMetadata.updatedAt,
                publicationDate: updatedMetadata.publicationDate,
                authors: updatedMetadata.authors,
                narrators: updatedMetadata.narrators,
                creators: updatedMetadata.creators,
                series: updatedMetadata.series,
                tags: updatedMetadata.tags,
                collections: updatedMetadata.collections,
                ebook: updatedMetadata.ebook,
                audiobook: updatedMetadata.audiobook,
                readaloud: updatedMetadata.readaloud,
                status: updatedMetadata.status,
                position: newPosition
            )
            localStorytellerMetadata[index] = updatedMetadata
            debugLog("[LocalMediaActor] updateBookProgress: updated storyteller metadata")
        }

        if let index = localStandaloneMetadata.firstIndex(where: { $0.uuid == bookId }) {
            var updatedMetadata = localStandaloneMetadata[index]
            let newPosition = BookReadingPosition(
                uuid: updatedMetadata.position?.uuid,
                locator: locator,
                timestamp: timestamp,
                createdAt: updatedMetadata.position?.createdAt,
                updatedAt: updatedAtString
            )
            updatedMetadata = BookMetadata(
                uuid: updatedMetadata.uuid,
                title: updatedMetadata.title,
                subtitle: updatedMetadata.subtitle,
                description: updatedMetadata.description,
                language: updatedMetadata.language,
                createdAt: updatedMetadata.createdAt,
                updatedAt: updatedMetadata.updatedAt,
                publicationDate: updatedMetadata.publicationDate,
                authors: updatedMetadata.authors,
                narrators: updatedMetadata.narrators,
                creators: updatedMetadata.creators,
                series: updatedMetadata.series,
                tags: updatedMetadata.tags,
                collections: updatedMetadata.collections,
                ebook: updatedMetadata.ebook,
                audiobook: updatedMetadata.audiobook,
                readaloud: updatedMetadata.readaloud,
                status: updatedMetadata.status,
                position: newPosition
            )
            localStandaloneMetadata[index] = updatedMetadata
            debugLog("[LocalMediaActor] updateBookProgress: updated standalone metadata")
        }
    }

    private func mergeWithLocalTimestamps(_ serverMetadata: [BookMetadata]) -> [BookMetadata] {
        return serverMetadata.map { serverBook in
            guard let localBook = localStorytellerMetadata.first(where: { $0.uuid == serverBook.uuid }),
                  let localTimestamp = localBook.position?.timestamp,
                  let serverTimestamp = serverBook.position?.timestamp,
                  localTimestamp > serverTimestamp else {
                return serverBook
            }

            debugLog("[LocalMediaActor] mergeWithLocalTimestamps: keeping local position for \(serverBook.uuid) (local=\(localTimestamp) > server=\(serverTimestamp))")

            return BookMetadata(
                uuid: serverBook.uuid,
                title: serverBook.title,
                subtitle: serverBook.subtitle,
                description: serverBook.description,
                language: serverBook.language,
                createdAt: serverBook.createdAt,
                updatedAt: serverBook.updatedAt,
                publicationDate: serverBook.publicationDate,
                authors: serverBook.authors,
                narrators: serverBook.narrators,
                creators: serverBook.creators,
                series: serverBook.series,
                tags: serverBook.tags,
                collections: serverBook.collections,
                ebook: serverBook.ebook,
                audiobook: serverBook.audiobook,
                readaloud: serverBook.readaloud,
                status: serverBook.status,
                position: localBook.position
            )
        }
    }

    private func applyOfflineProgressToMetadata(
        _ metadata: [BookMetadata],
        pendingSyncs: [PendingProgressSync]
    ) -> [BookMetadata] {
        guard !pendingSyncs.isEmpty else { return metadata }

        return metadata.map { book in
            guard let pending = pendingSyncs.first(where: { $0.bookId == book.uuid }) else {
                return book
            }

            let updatedAtString = Date(timeIntervalSince1970: pending.timestamp / 1000).ISO8601Format()

            let newPosition = BookReadingPosition(
                uuid: book.position?.uuid,
                locator: pending.locator,
                timestamp: pending.timestamp,
                createdAt: book.position?.createdAt,
                updatedAt: updatedAtString
            )

            return BookMetadata(
                uuid: book.uuid,
                title: book.title,
                subtitle: book.subtitle,
                description: book.description,
                language: book.language,
                createdAt: book.createdAt,
                updatedAt: book.updatedAt,
                publicationDate: book.publicationDate,
                authors: book.authors,
                narrators: book.narrators,
                creators: book.creators,
                series: book.series,
                tags: book.tags,
                collections: book.collections,
                ebook: book.ebook,
                audiobook: book.audiobook,
                readaloud: book.readaloud,
                status: book.status,
                position: newPosition
            )
        }
    }

    public func scanForMedia() async throws {
        try await filesystem.ensureLocalStorageDirectories()

        var storytellerMetadata: [BookMetadata]
        if let loaded = try await filesystem.loadStorytellerLibraryMetadata() {
            storytellerMetadata = loaded
        } else {
            storytellerMetadata = []
        }

        let pendingSyncs = await ProgressSyncActor.shared.getPendingProgressSyncs()
        localStorytellerMetadata = applyOfflineProgressToMetadata(storytellerMetadata, pendingSyncs: pendingSyncs)

        var storytellerPaths: [String: MediaPaths] = [:]
        for book in localStorytellerMetadata {
            let mediaPaths = await scanBookPaths(for: book.uuid, domain: .storyteller)
            storytellerPaths[book.uuid] = mediaPaths
        }
        localStorytellerBookPaths = storytellerPaths

        let localScanResult = try await localLibrary.scanLocalMedia(filesystem: filesystem)
        localStandaloneMetadata = localScanResult.metadata
        localStandaloneBookPaths = localScanResult.paths

        viewModelUpdateCallback?()
    }

    private func scanBookPaths(for uuid: String, domain: LocalMediaDomain) async -> MediaPaths {
        var paths = MediaPaths()
        let fm = FileManager.default

        for category in LocalMediaCategory.allCases {
            guard
                let categoryDir = await filesystem.mediaDirectory(
                    for: uuid,
                    category: category,
                    in: domain
                )
            else {
                continue
            }

            guard
                let contents = try? fm.contentsOfDirectory(
                    at: categoryDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            let expectedExtensions: [String]
            switch category {
                case .ebook:
                    expectedExtensions = ["epub"]
                case .audio:
                    expectedExtensions = ["m4b", "zip", "audiobook"]
                case .synced:
                    expectedExtensions = ["epub"]
            }

            if let firstFile = contents.first(where: { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory != true
                else {
                    return false
                }
                return expectedExtensions.contains(url.pathExtension.lowercased())
            }) {
                switch category {
                    case .ebook:
                        paths.ebookPath = firstFile
                    case .audio:
                        paths.audioPath = firstFile
                    case .synced:
                        paths.syncedPath = firstFile
                }
            }
        }

        return paths
    }

    public func listAvailableUuids() async -> Set<String> {
        do {
            try await filesystem.ensureLocalStorageDirectories()
            if let metadata = try await filesystem.loadStorytellerLibraryMetadata() {
                localStorytellerMetadata = metadata
                return Set(metadata.map(\.uuid))
            } else {
                return Set(localStorytellerMetadata.map(\.uuid))
            }
        } catch {
            debugLog("[LocalMediaActor] listAvailableUuids failed: \(error)")
            return Set(localStorytellerMetadata.map(\.uuid))
        }
    }

    public func downloadedCategories(for uuid: String) async -> Set<LocalMediaCategory> {
        await filesystem.downloadedCategories(for: uuid, in: .storyteller)
    }

    public func mediaDirectory(for uuid: String, category: LocalMediaCategory) async -> URL? {
        await filesystem.mediaDirectory(for: uuid, category: category, in: .storyteller)
    }

    public func deleteMedia(for uuid: String, category: LocalMediaCategory) async throws {
        try await filesystem.deleteMedia(
            for: uuid,
            category: category,
            in: .storyteller
        )

        let updatedPaths = await scanBookPaths(for: uuid, domain: .storyteller)
        localStorytellerBookPaths[uuid] = updatedPaths

        viewModelUpdateCallback?()
    }

    public func deleteLocalStandaloneMedia(for uuid: String) async throws {
        guard let paths = localStandaloneBookPaths[uuid] else {
            localStandaloneMetadata.removeAll { $0.uuid == uuid }
            try await filesystem.saveLocalLibraryMetadata(localStandaloneMetadata)
            viewModelUpdateCallback?()
            return
        }

        var bookFolder: URL?
        if let ebookPath = paths.ebookPath {
            bookFolder = ebookPath.deletingLastPathComponent().deletingLastPathComponent()
        } else if let audioPath = paths.audioPath {
            bookFolder = audioPath.deletingLastPathComponent().deletingLastPathComponent()
        } else if let syncedPath = paths.syncedPath {
            bookFolder = syncedPath.deletingLastPathComponent().deletingLastPathComponent()
        }

        if let folder = bookFolder {
            let fm = FileManager.default
            if fm.fileExists(atPath: folder.path) {
                try fm.removeItem(at: folder)
            }
        }

        localStandaloneBookPaths.removeValue(forKey: uuid)
        localStandaloneMetadata.removeAll { $0.uuid == uuid }
        try await filesystem.saveLocalLibraryMetadata(localStandaloneMetadata)

        viewModelUpdateCallback?()
    }

    /// Returns the base directory for the given domain, e.g. `<ApplicationSupport>/storyteller_media`.
    public func getDomainDirectory(for domain: LocalMediaDomain) async -> URL {
        await filesystem.getDomainDirectory(for: domain)
    }

    /// Returns the directory for the supplied domain/category pair and book name.
    /// - Parameters:
    ///   - domain: Storage domain (e.g. `.local`).
    ///   - category: Media category (e.g. `.audio`).
    ///   - bookName: Display name used for the nested book folder.
    ///   - uuidIdentifier: Optional identifier used to produce a stable folder name (e.g. a Storyteller book UUID).
    /// - Returns: `<ApplicationSupport>/<domain>/foo/<category>` when `bookName == "foo"`. Supplying a UUID ensures all imports reuse the same folder; without a UUID (local media) a numeric suffix is appended when a folder already exists.
    public func getMediaDirectory(
        domain: LocalMediaDomain,
        category: LocalMediaCategory,
        bookName: String,
        uuidIdentifier: String? = nil
    ) async -> URL {
        await filesystem.getMediaDirectory(
            domain: domain,
            category: category,
            bookName: bookName,
            uuidIdentifier: uuidIdentifier
        )
    }

    public static func category(forFileURL url: URL) throws -> LocalMediaCategory {
        let ext = url.pathExtension.lowercased()
        guard let category = Self.extensionCategoryMap[ext] else {
            throw LocalMediaError.unsupportedFileExtension(ext)
        }
        return category
    }

    public func extractLocalCover(for bookId: String) async -> Data? {
        guard let paths = localStandaloneBookPaths[bookId] else {
            return nil
        }

        if let ebookPath = paths.ebookPath {
            if let data = localLibrary.extractCoverFromEpub(at: ebookPath) {
                return data
            }
        }

        if let syncedPath = paths.syncedPath {
            if let data = localLibrary.extractCoverFromEpub(at: syncedPath) {
                return data
            }
        }

        if let audioPath = paths.audioPath {
            if let data = await localLibrary.extractCoverFromAudiobook(at: audioPath) {
                return data
            }
        }

        return nil
    }

    public func isLocalStandaloneBook(_ bookId: String) -> Bool {
        localStandaloneMetadata.contains { $0.uuid == bookId }
    }

    public func importMedia(
        from sourceFileURL: URL,
        domain: LocalMediaDomain,
        category: LocalMediaCategory,
        bookName: String
    ) async throws -> URL {
        let shouldStopAccessing = sourceFileURL.startAccessingSecurityScopedResource()
        defer { if shouldStopAccessing { sourceFileURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try await filesystem.ensureLocalStorageDirectories()

        if domain == .local {
            let metadata = try await localLibrary.extractMetadata(from: sourceFileURL, category: category)

            let destinationDirectory = await filesystem.getMediaDirectory(
                domain: domain,
                category: category,
                bookName: metadata.title,
                uuidIdentifier: metadata.uuid
            )
            let bookRoot = destinationDirectory.deletingLastPathComponent()
            try await filesystem.ensureDirectoryExists(at: bookRoot)
            try await filesystem.ensureDirectoryExists(at: destinationDirectory)

            let destinationURL = destinationDirectory.appendingPathComponent(
                sourceFileURL.lastPathComponent
            )
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }

            try fm.copyItem(at: sourceFileURL, to: destinationURL)

            localStandaloneMetadata.removeAll { $0.uuid == metadata.uuid }
            localStandaloneMetadata.append(metadata)
            try await filesystem.saveLocalLibraryMetadata(localStandaloneMetadata)

            let mediaPaths = await scanBookPaths(for: metadata.uuid, domain: .local)
            localStandaloneBookPaths[metadata.uuid] = mediaPaths

            viewModelUpdateCallback?()

            return destinationURL
        } else {
            let destinationDirectory = await filesystem.getMediaDirectory(
                domain: domain,
                category: category,
                bookName: bookName,
                uuidIdentifier: nil
            )
            let bookRoot = destinationDirectory.deletingLastPathComponent()
            try await filesystem.ensureDirectoryExists(at: bookRoot)
            try await filesystem.ensureDirectoryExists(at: destinationDirectory)

            let destinationURL = destinationDirectory.appendingPathComponent(
                sourceFileURL.lastPathComponent
            )
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }

            try fm.copyItem(at: sourceFileURL, to: destinationURL)

            viewModelUpdateCallback?()

            return destinationURL
        }
    }

    public func importMedia(
        for metadata: BookMetadata,
        category: LocalMediaCategory
    ) -> AsyncThrowingStream<LocalMediaImportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.streamStorytellerImport(
                        metadata: metadata,
                        category: category,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func streamStorytellerImport(
        metadata: BookMetadata,
        category: LocalMediaCategory,
        continuation: AsyncThrowingStream<LocalMediaImportEvent, Error>.Continuation
    ) async throws {
        try await filesystem.ensureLocalStorageDirectories()

        let destinationDirectory = await filesystem.getMediaDirectory(
            domain: .storyteller,
            category: category,
            bookName: metadata.title,
            uuidIdentifier: metadata.uuid
        )
        let bookRoot = destinationDirectory.deletingLastPathComponent()
        try await filesystem.ensureDirectoryExists(at: bookRoot)

        let fm = FileManager.default

        let assetInfo = storytellerAssetInfo(for: metadata, category: category)
        guard assetInfo.available else {
            continuation.yield(.skipped(book: metadata, category: category))
            return
        }

        guard
            let download = await StorytellerActor.shared.fetchBook(
                for: metadata.uuid,
                format: assetInfo.format
            )
        else {
            continuation.yield(.skipped(book: metadata, category: category))
            return
        }

        try await filesystem.ensureDirectoryExists(at: destinationDirectory)

        var currentFilename = download.initialFilename
        var expectedBytes: Int64? = nil
        var started = false
        var lastReported: Int64 = -1

        do {
            for try await event in download.events {
                try Task.checkCancellation()
                switch event {
                    case .response(let filename, let expected, _, _, _):
                        currentFilename = filename
                        expectedBytes = expected
                        if !started {
                            started = true
                            continuation.yield(
                                .started(
                                    book: metadata,
                                    category: category,
                                    expectedBytes: expectedBytes
                                )
                            )
                        }
                    case .progress(let receivedBytes, let eventExpected):
                        if !started {
                            started = true
                            expectedBytes = eventExpected ?? expectedBytes
                            continuation.yield(
                                .started(
                                    book: metadata,
                                    category: category,
                                    expectedBytes: expectedBytes
                                )
                            )
                        }
                        expectedBytes = eventExpected ?? expectedBytes
                        guard receivedBytes != lastReported else { continue }
                        lastReported = receivedBytes
                        continuation.yield(
                            .progress(
                                book: metadata,
                                category: category,
                                receivedBytes: receivedBytes,
                                expectedBytes: expectedBytes
                            )
                        )
                    case .finished(let tempURL):
                        if !started {
                            started = true
                            continuation.yield(
                                .started(
                                    book: metadata,
                                    category: category,
                                    expectedBytes: expectedBytes
                                )
                            )
                        }

                        let destinationURL = destinationDirectory.appendingPathComponent(
                            currentFilename
                        )
                        if fm.fileExists(atPath: destinationURL.path) {
                            try fm.removeItem(at: destinationURL)
                        }

                        var shouldRemoveTemp = true
                        defer {
                            if shouldRemoveTemp {
                                try? fm.removeItem(at: tempURL)
                            }
                        }

                        do {
                            try fm.moveItem(at: tempURL, to: destinationURL)
                            shouldRemoveTemp = false
                        } catch {
                            throw error
                        }

                        continuation.yield(
                            .finished(
                                book: metadata,
                                category: category,
                                destination: destinationURL
                            )
                        )

                        do {
                            try await scanForMedia()
                        } catch {
                            debugLog(
                                "[LocalMediaActor] scanForMedia post-download failed: \(error)"
                            )
                        }
                        return
                }
            }
        } catch is CancellationError {
            download.cancel()
            throw CancellationError()
        } catch is StorytellerDownloadFailure {
            continuation.yield(.skipped(book: metadata, category: category))
        }
    }

    public func ensureLocalStorageDirectories() async throws {
        try await filesystem.ensureLocalStorageDirectories()
    }

    public func removeAllStorytellerData() async throws {
        try await filesystem.removeAllStorytellerData()

        localStorytellerMetadata = []
        localStorytellerBookPaths = [:]

        viewModelUpdateCallback?()
    }

    private func storytellerAssetInfo(
        for metadata: BookMetadata,
        category: LocalMediaCategory
    ) -> (available: Bool, format: StorytellerBookFormat) {
        switch category {
            case .ebook:
                return (metadata.hasAvailableEbook, .ebook)
            case .audio:
                return (metadata.hasAvailableAudiobook, .audiobook)
            case .synced:
                return (metadata.hasAvailableReadaloud, .readaloud)
        }
    }

}

public enum LocalMediaDomain: String, CaseIterable, Sendable {
    case local = "local_media"
    case storyteller = "storyteller_media"

}

public enum LocalMediaCategory: String, CaseIterable, Sendable, Codable {
    case audio
    case ebook
    case synced
}

enum LocalMediaError: Error, Sendable {
    case unsupportedFileExtension(String)
}

extension LocalMediaError: LocalizedError {
    var errorDescription: String? {
        switch self {
            case .unsupportedFileExtension(let ext):
                "Unsupported media file extension: \(ext)"
        }
    }
}
