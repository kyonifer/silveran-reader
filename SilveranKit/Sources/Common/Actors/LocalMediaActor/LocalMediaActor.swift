import Foundation
import ZIPFoundation

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

@globalActor
public actor LocalMediaActor: GlobalActor {
    public static let shared = LocalMediaActor()
    private var sourceCacheMetadata: [BookMetadata] = []
    private(set) public var sourceCacheBookPaths: [String: MediaPaths] = [:]
    private let filesystem: FilesystemActor
    private let localLibrary: LocalLibraryManager
    private var periodicScanTask: Task<Void, Never>?

    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var sourceCacheLoaded = false

    public init(
        filesystem: FilesystemActor = .shared,
        localLibrary: LocalLibraryManager = LocalLibraryManager(),
    ) {
        self.filesystem = filesystem
        self.localLibrary = localLibrary
        Task { [weak self] in
            await SilveranMigrations.ensureMigrationsRan()
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

    @discardableResult
    public func addObserver(_ callback: @escaping @Sendable @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        debugLog("[LMA] addObserver: id=\(id), total observers=\(observers.count)")
        return id
    }

    private func notifyObservers() async {
        debugLog("[LMA] notifyObservers: notifying \(observers.count) observers")
        for (_, callback) in observers {
            await callback()
        }
    }

    private func metadata(
        _ metadata: [BookMetadata],
        stampedWith sourceID: BookSourceID,
    ) -> [BookMetadata] {
        metadata.map { book in
            var stamped = book
            stamped.sourceID = stamped.sourceID ?? sourceID
            return stamped
        }
    }

    public func updateSourceCacheMetadata(
        _ metadata: [BookMetadata],
        replacingSourceID sourceID: BookSourceID? = nil,
    ) async throws {
        await SilveranMigrations.ensureMigrationsRan()
        _ = try await filesystem.loadOrCreateBookSources()
        let nextMetadata: [BookMetadata]
        if let sourceID {
            let stampedMetadata = self.metadata(
                metadata,
                stampedWith: sourceID,
            )
            let preserved = sourceCacheMetadata.filter {
                $0.sourceID != sourceID
            }
            nextMetadata = preserved + stampedMetadata
        } else {
            let incomingBySourceID = metadataBySourceID(metadata)
            guard !incomingBySourceID.isEmpty else { return }
            let replacedSourceIDs = Set(incomingBySourceID.keys)
            let preserved = sourceCacheMetadata.filter { book in
                guard let sourceID = book.sourceID else { return false }
                return !replacedSourceIDs.contains(sourceID)
            }
            nextMetadata = preserved + incomingBySourceID.values.flatMap { $0 }
        }
        sourceCacheMetadata = nextMetadata
        sourceCacheLoaded = true
        let grouped = metadataBySourceID(nextMetadata)
        if let sourceID, grouped[sourceID] == nil {
            try await filesystem.saveSourceCacheLibraryMetadata([], sourceID: sourceID)
        }
        for (groupSourceID, groupMetadata) in grouped {
            try await filesystem.saveSourceCacheLibraryMetadata(
                groupMetadata,
                sourceID: groupSourceID,
            )
        }

        var paths: [String: MediaPaths] = [:]
        for book in nextMetadata {
            guard let sourceID = book.sourceID else { continue }
            let mediaPaths = await scanBookPaths(
                for: book.uuid,
                sourceID: sourceID,
            )
            paths[book.uuid] = mediaPaths
        }
        sourceCacheBookPaths = paths

        let positions = Dictionary(
            uniqueKeysWithValues: nextMetadata.compactMap {
                book -> (String, BookReadingPosition)? in
                guard let pos = book.position else { return nil }
                return (book.uuid, pos)
            }
        )
        await ProgressSyncActor.shared.updateServerPositions(positions)

        await notifyObservers()
    }

    public func updateSourceCacheBookMetadata(
        _ metadata: BookMetadata,
        sourceID: BookSourceID,
    ) async throws {
        await SilveranMigrations.ensureMigrationsRan()
        _ = try await filesystem.loadOrCreateBookSources()
        await ensureSourceCacheLoaded()

        var stamped = metadata
        stamped.sourceID = stamped.sourceID ?? sourceID

        sourceCacheMetadata.removeAll {
            $0.uuid == stamped.uuid && $0.sourceID == sourceID
        }
        sourceCacheMetadata.append(stamped)
        sourceCacheLoaded = true

        let grouped = metadataBySourceID(sourceCacheMetadata)
        if let sourceMetadata = grouped[sourceID] {
            try await filesystem.saveSourceCacheLibraryMetadata(
                sourceMetadata,
                sourceID: sourceID,
            )
        } else {
            try await filesystem.saveSourceCacheLibraryMetadata([], sourceID: sourceID)
        }

        sourceCacheBookPaths[stamped.uuid] = await scanBookPaths(
            for: stamped.uuid,
            sourceID: sourceID,
        )

        await notifyObservers()
    }

    public func libraryMetadata() async -> [BookMetadata] {
        await ensureSourceCacheLoaded()
        return sourceCacheMetadata
    }

    private func ensureSourceCacheLoaded() async {
        await SilveranMigrations.ensureMigrationsRan()
        guard !sourceCacheLoaded else { return }
        do {
            try await scanForMedia()
        } catch {
            debugLog("[LocalMediaActor] ensureSourceCacheLoaded failed: \(error)")
        }
    }

    private func metadataBySourceID(_ metadata: [BookMetadata])
        -> [BookSourceID: [BookMetadata]]
    {
        var grouped: [BookSourceID: [BookMetadata]] = [:]
        for book in metadata {
            guard let sourceID = book.sourceID else { continue }
            grouped[sourceID, default: []].append(book)
        }
        return grouped
    }

    public func updateBookProgress(bookId: String, locator: BookLocator, timestamp: Double) async {
        debugLog("[LocalMediaActor] updateBookProgress: bookId=\(bookId), timestamp=\(timestamp)")

        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()

        if let index = sourceCacheMetadata.firstIndex(where: { $0.uuid == bookId }) {
            let existing = sourceCacheMetadata[index]
            let existingTimestamp = existing.position?.timestamp ?? 0

            if timestamp <= existingTimestamp {
                debugLog(
                    "[LocalMediaActor] updateBookProgress: skipping source-cache update, existing is newer (incoming: \(timestamp), existing: \(existingTimestamp))"
                )
            } else {
                let newPosition = BookReadingPosition(
                    uuid: existing.position?.uuid,
                    locator: locator,
                    timestamp: timestamp,
                    createdAt: existing.position?.createdAt,
                    updatedAt: updatedAtString,
                )
                var updatedMetadata = BookMetadata(
                    uuid: existing.uuid,
                    title: existing.title,
                    subtitle: existing.subtitle,
                    description: existing.description,
                    language: existing.language,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt,
                    publicationDate: existing.publicationDate,
                    authors: existing.authors,
                    narrators: existing.narrators,
                    creators: existing.creators,
                    series: existing.series,
                    tags: existing.tags,
                    collections: existing.collections,
                    ebook: existing.ebook,
                    audiobook: existing.audiobook,
                    readaloud: existing.readaloud,
                    status: existing.status,
                    position: newPosition,
                    rating: existing.rating,
                )
                updatedMetadata.sourceID =
                    existing.sourceID
                updatedMetadata.source = existing.source
                sourceCacheMetadata[index] = updatedMetadata
                debugLog("[LocalMediaActor] updateBookProgress: updated source-cache metadata")
                if let sourceID = updatedMetadata.sourceID {
                    let sourceMetadata = sourceCacheMetadata.filter { $0.sourceID == sourceID }
                    do {
                        try await filesystem.saveSourceCacheLibraryMetadata(
                            sourceMetadata,
                            sourceID: sourceID,
                        )
                        debugLog(
                            "[LocalMediaActor] updateBookProgress: persisted source-cache metadata"
                        )
                    } catch {
                        debugLog(
                            "[LocalMediaActor] updateBookProgress: failed to persist source-cache metadata: \(error)"
                        )
                    }
                }
            }
        }

        // Folder sources persist progress through FolderSourceActor. LocalMediaActor only tracks
        // client-owned cache state.
    }

    public func scanForMedia() async throws {
        await SilveranMigrations.ensureMigrationsRan()
        try await filesystem.ensureLocalStorageDirectories()
        let bookSources = try await filesystem.loadOrCreateBookSources()

        var cachedMetadata: [BookMetadata] = []
        for source in bookSources {
            guard source.kind != .localFolder else { continue }
            guard
                let loadedMetadata = try await filesystem.loadSourceCacheLibraryMetadata(
                    sourceID: source.id
                )
            else { continue }
            let stampedMetadata = metadata(loadedMetadata, stampedWith: source.id)
            cachedMetadata.append(contentsOf: stampedMetadata)
            if stampedMetadata != loadedMetadata {
                try await filesystem.saveSourceCacheLibraryMetadata(
                    stampedMetadata,
                    sourceID: source.id,
                )
            }
        }

        sourceCacheMetadata = cachedMetadata
        sourceCacheLoaded = true

        var cachedPaths: [String: MediaPaths] = [:]
        for book in sourceCacheMetadata {
            guard let sourceID = book.sourceID else { continue }
            let mediaPaths = await scanBookPaths(
                for: book.uuid,
                sourceID: sourceID,
            )
            cachedPaths[book.uuid] = mediaPaths
        }
        sourceCacheBookPaths = cachedPaths

        var allPositions: [String: BookReadingPosition] = [:]
        for book in cachedMetadata {
            if let pos = book.position {
                allPositions[book.uuid] = pos
            }
        }
        await ProgressSyncActor.shared.updateServerPositions(allPositions)

        await notifyObservers()
    }

    private func scanBookPaths(
        for uuid: String,
        sourceID: BookSourceID,
    ) async -> MediaPaths {
        var paths = MediaPaths()
        let fm = FileManager.default

        for category in LocalMediaCategory.allCases {
            guard
                let categoryDir = await filesystem.mediaDirectory(
                    for: uuid,
                    category: category,
                    sourceID: sourceID,
                )
            else {
                continue
            }

            guard
                let contents = try? fm.contentsOfDirectory(
                    at: categoryDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles],
                )
            else {
                continue
            }

            switch category {
                case .ebook:
                    paths.ebookPath = firstMediaFile(in: contents, matchingExtensions: ["epub"])
                case .audio:
                    paths.audioPath = audioManifestFile(in: categoryDir)
                case .synced:
                    paths.syncedPath = firstMediaFile(in: contents, matchingExtensions: ["epub"])
            }
        }

        return paths
    }

    public func cachedMediaPaths(for metadata: [BookMetadata]) async -> [String: MediaPaths] {
        await SilveranMigrations.ensureMigrationsRan()
        var paths = sourceCacheBookPaths
        for book in metadata {
            guard let sourceID = book.sourceID else { continue }
            var mediaPaths = paths[book.uuid] ?? MediaPaths()
            if mediaPaths.ebookPath == nil {
                mediaPaths.ebookPath = await mediaFilePath(
                    for: book.uuid,
                    category: .ebook,
                    sourceID: sourceID,
                )
            }
            if mediaPaths.audioPath == nil {
                mediaPaths.audioPath = await mediaFilePath(
                    for: book.uuid,
                    category: .audio,
                    sourceID: sourceID,
                )
            }
            if mediaPaths.syncedPath == nil {
                mediaPaths.syncedPath = await mediaFilePath(
                    for: book.uuid,
                    category: .synced,
                    sourceID: sourceID,
                )
            }
            if mediaPaths.ebookPath != nil || mediaPaths.audioPath != nil
                || mediaPaths.syncedPath != nil
            {
                paths[book.uuid] = mediaPaths
            }
        }
        return paths
    }

    public func mediaFilePath(
        for uuid: String,
        category: LocalMediaCategory,
        sourceID explicitSourceID: BookSourceID? = nil,
    ) async -> URL? {
        if let paths = sourceCacheBookPaths[uuid] {
            switch category {
                case .ebook: return paths.ebookPath
                case .audio: return paths.audioPath
                case .synced: return paths.syncedPath
            }
        }
        guard let sourceID = await cacheSourceID(for: uuid, explicitSourceID: explicitSourceID)
        else { return nil }
        guard
            let categoryDir = await filesystem.mediaDirectory(
                for: uuid,
                category: category,
                sourceID: sourceID,
            )
        else { return nil }

        var paths = await scanBookPaths(for: uuid, sourceID: sourceID)
        sourceCacheBookPaths[uuid] = paths
        switch category {
            case .ebook:
                if paths.ebookPath == nil {
                    paths.ebookPath = firstCachedMediaFile(in: categoryDir, category: category)
                }
                return paths.ebookPath
            case .audio:
                if paths.audioPath == nil {
                    paths.audioPath = firstCachedMediaFile(in: categoryDir, category: category)
                }
                return paths.audioPath
            case .synced:
                if paths.syncedPath == nil {
                    paths.syncedPath = firstCachedMediaFile(in: categoryDir, category: category)
                }
                return paths.syncedPath
        }
    }

    private func cacheSourceID(
        for uuid: String,
        explicitSourceID: BookSourceID?,
    ) async -> BookSourceID? {
        if let explicitSourceID {
            return explicitSourceID
        }
        if let metadataSourceID = sourceCacheMetadata.first(where: { $0.uuid == uuid })?.sourceID {
            return metadataSourceID
        }
        return nil
    }

    private func firstCachedMediaFile(in categoryDir: URL, category: LocalMediaCategory) -> URL? {
        switch category {
            case .ebook, .synced:
                guard
                    let contents = try? FileManager.default.contentsOfDirectory(
                        at: categoryDir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles],
                    )
                else {
                    return nil
                }
                return firstMediaFile(in: contents, matchingExtensions: ["epub"])
            case .audio:
                return audioManifestFile(in: categoryDir)
        }
    }

    private func firstMediaFile(in contents: [URL], matchingExtensions extensions: Set<String>)
        -> URL?
    {
        return contents.first { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory != true
            else {
                return false
            }
            return extensions.contains(url.pathExtension.lowercased())
        }
    }

    private func audioManifestFile(in audioDirectory: URL) -> URL? {
        let manifestURL = audioDirectory.appendingPathComponent(
            "manifest.json",
            isDirectory: false,
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        return manifestURL
    }

    public func deleteMedia(
        for uuid: String,
        category: LocalMediaCategory,
        sourceID explicitSourceID: BookSourceID? = nil,
    ) async throws {
        guard let sourceID = await cacheSourceID(for: uuid, explicitSourceID: explicitSourceID)
        else { return }
        try await filesystem.deleteMedia(
            for: uuid,
            category: category,
            sourceID: sourceID,
        )

        let updatedPaths = await scanBookPaths(
            for: uuid,
            sourceID: sourceID,
        )
        if updatedPaths.ebookPath == nil && updatedPaths.audioPath == nil
            && updatedPaths.syncedPath == nil
        {
            sourceCacheBookPaths.removeValue(forKey: uuid)
        } else {
            sourceCacheBookPaths[uuid] = updatedPaths
        }

        await notifyObservers()
    }

    public func ensureLocalStorageDirectories() async throws {
        try await filesystem.ensureLocalStorageDirectories()
    }

    /// Import a pre-downloaded file into LMA storage. Used by watch for background downloads
    /// and iPhone transfers. Uses moveItem (not copy) to avoid doubling storage usage.
    public func importDownloadedFile(
        from tempURL: URL,
        metadata: BookMetadata,
        category: LocalMediaCategory,
        filename: String,
        audioIsPackage: Bool = true,
    ) async throws {
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await filesystem.ensureLocalStorageDirectories()
        let cacheSourceID: BookSourceID
        if let sourceID = metadata.sourceID {
            cacheSourceID = sourceID
        } else {
            throw LocalMediaError.importFailed("Book source is not configured")
        }

        let destinationDirectory = await filesystem.getMediaDirectory(
            category: category,
            bookName: metadata.title,
            uuidIdentifier: metadata.uuid,
            sourceID: cacheSourceID,
        )
        let bookRoot = destinationDirectory.deletingLastPathComponent()
        try await filesystem.ensureDirectoryExists(at: bookRoot)
        try await filesystem.ensureDirectoryExists(at: destinationDirectory)

        let fm = FileManager.default
        if category == .audio && audioIsPackage {
            if fm.fileExists(atPath: destinationDirectory.path) {
                try fm.removeItem(at: destinationDirectory)
            }
            try await filesystem.ensureDirectoryExists(at: destinationDirectory)

            do {
                try extractAudiobookPackage(from: tempURL, to: destinationDirectory)
                guard
                    fm.fileExists(
                        atPath: destinationDirectory.appendingPathComponent("manifest.json").path
                    )
                else {
                    throw LocalMediaError.missingAudiobookManifest
                }
                debugLog(
                    "[LMA] importDownloadedFile: extracted audiobook package to \(destinationDirectory.path)"
                )
                try await scanForMedia()
                return
            } catch {
                if fm.fileExists(atPath: destinationDirectory.path) {
                    try? fm.removeItem(at: destinationDirectory)
                }
                throw error
            }
        }

        let destinationURL = destinationDirectory.appendingPathComponent(filename)

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        try fm.moveItem(at: tempURL, to: destinationURL)

        debugLog("[LMA] importDownloadedFile: moved \(filename) to \(destinationURL.path)")

        try await scanForMedia()
    }

    public func removeSourceCacheData(sourceID: BookSourceID) async throws {
        await ensureSourceCacheLoaded()
        let booksToRemove = sourceCacheMetadata.filter {
            $0.sourceID == sourceID
        }

        for book in booksToRemove {
            try await filesystem.removeSourceCacheBookData(uuid: book.uuid, sourceID: sourceID)
        }

        sourceCacheMetadata.removeAll {
            $0.sourceID == sourceID
        }
        try await filesystem.saveSourceCacheLibraryMetadata([], sourceID: sourceID)

        var paths: [String: MediaPaths] = [:]
        for book in sourceCacheMetadata {
            guard let sourceID = book.sourceID else { continue }
            let mediaPaths = await scanBookPaths(
                for: book.uuid,
                sourceID: sourceID,
            )
            paths[book.uuid] = mediaPaths
        }
        sourceCacheBookPaths = paths

        await notifyObservers()
    }

    private func extractAudiobookPackage(from archiveURL: URL, to destinationDirectory: URL) throws
    {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let fm = FileManager.default

        for entry in archive {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..")
            else {
                continue
            }
            let destinationURL = destinationDirectory.appendingPathComponent(entry.path)
            if entry.type == .directory {
                try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            try fm.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            _ = try archive.extract(entry, to: destinationURL)
        }
    }

}

public enum LocalMediaCategory: String, CaseIterable, Sendable, Codable {
    case audio
    case ebook
    case synced
}

enum LocalMediaError: Error, Sendable {
    case missingAudiobookManifest
    case importFailed(String)
}

extension LocalMediaError: LocalizedError {
    var errorDescription: String? {
        switch self {
            case .missingAudiobookManifest:
                "Audiobook package is missing manifest.json"
            case .importFailed(let message):
                message
        }
    }
}
