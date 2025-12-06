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
    private var pendingProgressQueue: [PendingProgressSync] = []

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
            await self?.loadProgressQueue()
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
        let enrichedMetadata = applyOfflineProgressToMetadata(metadata)
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

    private func loadProgressQueue() async {
        do {
            pendingProgressQueue = try await filesystem.loadProgressQueue()
            debugLog(
                "[LocalMediaActor] loadProgressQueue: Loaded \(pendingProgressQueue.count) pending progress syncs"
            )
            if !pendingProgressQueue.isEmpty {
                for (index, item) in pendingProgressQueue.enumerated() {
                    debugLog(
                        "[LocalMediaActor] loadProgressQueue: [\(index)] bookId: \(item.bookId), timestamp: \(item.timestamp), attempts: \(item.attemptCount)"
                    )
                }
            }
        } catch {
            debugLog("[LocalMediaActor] loadProgressQueue: Failed to load progress queue: \(error)")
            pendingProgressQueue = []
        }
    }

    private func saveProgressQueue() async {
        do {
            debugLog(
                "[LocalMediaActor] saveProgressQueue: Saving queue with \(pendingProgressQueue.count) items"
            )
            if !pendingProgressQueue.isEmpty {
                let bookIds = pendingProgressQueue.map { $0.bookId }.joined(separator: ", ")
                debugLog("[LocalMediaActor] saveProgressQueue: bookIds: [\(bookIds)]")
            }
            try await filesystem.saveProgressQueue(pendingProgressQueue)
            debugLog("[LocalMediaActor] saveProgressQueue: Save complete")
        } catch {
            debugLog("[LocalMediaActor] saveProgressQueue: FAILED to save: \(error)")
        }
    }

    public func queueOfflineProgress(bookId: String, locator: BookLocator, timestamp: Double) async
    {
        debugLog("[LocalMediaActor] queueOfflineProgress CALLED for bookId: \(bookId)")
        Thread.callStackSymbols.prefix(10).forEach { debugLog("[LocalMediaActor] STACK: \($0)") }

        let wasInQueue = pendingProgressQueue.contains { $0.bookId == bookId }
        let queueCountBefore = pendingProgressQueue.count
        pendingProgressQueue.removeAll { $0.bookId == bookId }

        let pending = PendingProgressSync(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp
        )
        pendingProgressQueue.append(pending)

        debugLog(
            "[LocalMediaActor] queueOfflineProgress: bookId: \(bookId), wasInQueue: \(wasInQueue), queueCount: \(queueCountBefore) -> \(pendingProgressQueue.count)"
        )

        await saveProgressQueue()

        if let index = localStorytellerMetadata.firstIndex(where: { $0.uuid == bookId }) {
            var updatedMetadata = localStorytellerMetadata[index]
            let newPosition = BookReadingPosition(
                uuid: updatedMetadata.position?.uuid,
                locator: locator,
                timestamp: timestamp,
                createdAt: nil,
                updatedAt: nil
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
        }

        viewModelUpdateCallback?()
    }

    public func getOfflineProgress(for bookId: String) -> PendingProgressSync? {
        pendingProgressQueue.first { $0.bookId == bookId }
    }

    public func getAllPendingProgressSyncs() -> [PendingProgressSync] {
        pendingProgressQueue
    }

    public func removeSyncedProgress(bookId: String) async {
        let wasInQueue = pendingProgressQueue.contains { $0.bookId == bookId }
        let queueCountBefore = pendingProgressQueue.count
        pendingProgressQueue.removeAll { $0.bookId == bookId }
        let queueCountAfter = pendingProgressQueue.count

        debugLog(
            "[LocalMediaActor] removeSyncedProgress: bookId: \(bookId), wasInQueue: \(wasInQueue), queueCount: \(queueCountBefore) -> \(queueCountAfter)"
        )

        await saveProgressQueue()
        viewModelUpdateCallback?()
    }

    public func incrementSyncAttempt(bookId: String) async {
        if let index = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
            let oldCount = pendingProgressQueue[index].attemptCount
            pendingProgressQueue[index].attemptCount += 1
            debugLog(
                "[LocalMediaActor] incrementSyncAttempt: bookId: \(bookId), attemptCount: \(oldCount) -> \(pendingProgressQueue[index].attemptCount)"
            )
            await saveProgressQueue()
        } else {
            debugLog("[LocalMediaActor] incrementSyncAttempt: bookId: \(bookId) NOT FOUND in queue")
        }
    }

    private func applyOfflineProgressToMetadata(_ metadata: [BookMetadata]) -> [BookMetadata] {
        guard !pendingProgressQueue.isEmpty else { return metadata }

        return metadata.map { book in
            guard let pending = pendingProgressQueue.first(where: { $0.bookId == book.uuid }) else {
                return book
            }

            let newPosition = BookReadingPosition(
                uuid: book.position?.uuid,
                locator: pending.locator,
                timestamp: pending.timestamp,
                createdAt: nil,
                updatedAt: nil
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

        localStorytellerMetadata = applyOfflineProgressToMetadata(storytellerMetadata)

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
        for category in LocalMediaCategory.allCases {
            try await filesystem.deleteMedia(
                for: uuid,
                category: category,
                in: .local
            )
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
