import Foundation
import ZIPFoundation

#if canImport(AVFoundation)
import AVFoundation
#endif

public actor FolderSourceActor: BookSourceActor {
    private let sourceRecordValue: BookSourceRecord
    private let filesystem: FilesystemActor
    private let localLibrary: LocalLibraryManager

    private var metadataCache: [BookMetadata] = []
    private var pathCache: [String: MediaPaths] = [:]
    private var activeFolderAccessURL: URL?
    private var activeFolderAccessDidStart = false

    public init(
        sourceRecord: BookSourceRecord,
        filesystem: FilesystemActor = .shared,
        localLibrary: LocalLibraryManager = LocalLibraryManager(),
    ) {
        self.sourceRecordValue = sourceRecord
        self.filesystem = filesystem
        self.localLibrary = localLibrary
    }

    deinit {
        if activeFolderAccessDidStart {
            activeFolderAccessURL?.stopAccessingSecurityScopedResource()
        }
    }

    public var sourceRecord: BookSourceRecord {
        sourceRecordValue
    }

    public var connectionStatus: ConnectionStatus {
        .connected
    }

    public func fetchLibraryInformation() async -> [BookMetadata]? {
        do {
            let library = try await scanLibrary()
            metadataCache = library.metadata
            pathCache = library.paths
            return library.metadata
        } catch {
            debugLog("[FolderSourceActor] Failed to fetch library: \(error)")
            return nil
        }
    }

    public func fetchCoverImage(
        for bookId: String,
        audio _: Bool,
        width _: Int?,
        height _: Int?,
        version _: String?,
        ifNoneMatch _: String?,
        ifModifiedSince _: String?,
    ) async -> BookCover? {
        guard let data = await extractCover(for: bookId) else {
            return nil
        }
        return BookCover(
            data: data,
            contentType: nil,
            etag: nil,
            lastModified: nil,
            cacheControl: nil,
            contentDisposition: nil,
        )
    }

    public func sendProgressToServer(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async -> HTTPResult {
        do {
            try await updateBookProgress(bookId: bookId, locator: locator, timestamp: timestamp)
            return .success
        } catch {
            debugLog("[FolderSourceActor] Failed to save progress: \(error)")
            return .failure
        }
    }

    public func fetchBookPosition(bookId: String) async -> BookReadingPosition? {
        if let position = metadataCache.first(where: { $0.uuid == bookId })?.position {
            return position
        }
        guard let metadata = await fetchLibraryInformation() else { return nil }
        return metadata.first(where: { $0.uuid == bookId })?.position
    }

    public func localMediaReference(
        for bookID: String,
        category: LocalMediaCategory,
    ) async -> ResolvedLocalMedia? {
        if pathCache[bookID] == nil {
            _ = await fetchLibraryInformation()
        }
        do {
            try await retainFolderAccessForResolvedMedia()
        } catch {
            debugLog("[FolderSourceActor] Failed to retain folder access: \(error)")
            return nil
        }
        guard let paths = pathCache[bookID] else { return nil }
        let url: URL?
        switch category {
            case .ebook:
                url = paths.ebookPath
            case .audio:
                url = paths.audioPath
            case .synced:
                url = paths.syncedPath
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return ResolvedLocalMedia(
            bookID: bookID,
            sourceID: sourceRecordValue.id,
            category: category,
            url: url,
            kind: .source,
        )
    }

    public func closeFolderAccess() {
        if activeFolderAccessDidStart {
            activeFolderAccessURL?.stopAccessingSecurityScopedResource()
        }
        activeFolderAccessURL = nil
        activeFolderAccessDidStart = false
    }

    private func retainFolderAccessForResolvedMedia() async throws {
        if let activeFolderAccessURL,
            FileManager.default.fileExists(atPath: activeFolderAccessURL.path)
        {
            return
        }

        closeFolderAccess()

        guard let resolved = sourceFolderURL(sourceRecordValue) else {
            throw LocalMediaError.importFailed("Folder source has no storage location")
        }

        try await filesystem.ensureDirectoryExists(at: resolved.url)
        activeFolderAccessURL = resolved.url
        activeFolderAccessDidStart = resolved.didStartAccessing
    }

    public func updateStatus(forBooks bookIds: [String], to status: BookStatus) async -> Bool {
        guard !bookIds.isEmpty else { return false }
        do {
            let resolved = try await resolvedFolderURL()
            defer { stopAccessing(resolved) }

            if metadataCache.isEmpty {
                _ = try await scanLibrary(in: resolved.url)
            }

            var latestMetadata = try await savedMetadata(in: resolved.url)
            var updatedAny = false
            for bookId in bookIds {
                guard let index = latestMetadata.firstIndex(where: { $0.uuid == bookId }) else {
                    continue
                }
                latestMetadata[index] = metadata(
                    latestMetadata[index],
                    status: status,
                )
                updatedAny = true
            }

            guard updatedAny else { return false }
            try await filesystem.saveFolderSourceLibraryMetadata(
                latestMetadata,
                in: resolved.url,
            )
            metadataCache = latestMetadata
            return true
        } catch {
            debugLog("[FolderSourceActor] Failed to save status: \(error)")
            return false
        }
    }

    public func copyMediaToTemporaryFile(
        for bookID: String,
        category: LocalMediaCategory,
    ) async throws -> (url: URL, filename: String)? {
        if pathCache[bookID] == nil {
            _ = await fetchLibraryInformation()
        }
        guard let paths = pathCache[bookID] else { return nil }
        let sourceURL: URL?
        switch category {
            case .ebook:
                sourceURL = paths.ebookPath
            case .audio:
                sourceURL = paths.audioPath
            case .synced:
                sourceURL = paths.syncedPath
        }
        guard let sourceURL else { return nil }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SilveranFolderSourceDownloads", isDirectory: true)
        try await filesystem.ensureDirectoryExists(at: tempDirectory)

        let isAudiobook = category == .audio
        let filename =
            isAudiobook
            ? "\(sourceURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent).audiobook"
            : sourceURL.lastPathComponent
        let tempURL = tempDirectory.appendingPathComponent(
            "\(UUID().uuidString)-\(filename)",
            isDirectory: false,
        )
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        if isAudiobook {
            try createAudiobookArchive(
                from: sourceURL.deletingLastPathComponent(),
                at: tempURL,
            )
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        }
        return (tempURL, filename)
    }

    public func importMedia(
        from sourceFileURL: URL,
        category: LocalMediaCategory,
        bookName: String,
        bookUUID: String? = nil,
    ) async throws -> URL {
        let shouldStopAccessingSource = sourceFileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessingSource {
                sourceFileURL.stopAccessingSecurityScopedResource()
            }
        }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        let extractedMetadata = try await extractImportMetadata(
            from: sourceFileURL,
            category: category,
        )
        let importUUID = bookUUID ?? extractedMetadata.uuid
        var metadata = mergedBookMetadata(
            scanned: extractedMetadata,
            saved: BookMetadata(
                uuid: importUUID,
                title: extractedMetadata.title,
                subtitle: extractedMetadata.subtitle,
                description: extractedMetadata.description,
                language: extractedMetadata.language,
                createdAt: extractedMetadata.createdAt,
                updatedAt: extractedMetadata.updatedAt,
                publicationDate: extractedMetadata.publicationDate,
                authors: extractedMetadata.authors,
                narrators: extractedMetadata.narrators,
                creators: extractedMetadata.creators,
                series: extractedMetadata.series,
                tags: extractedMetadata.tags,
                collections: extractedMetadata.collections,
                ebook: extractedMetadata.ebook,
                audiobook: extractedMetadata.audiobook,
                readaloud: extractedMetadata.readaloud,
                status: extractedMetadata.status,
                position: extractedMetadata.position,
                rating: extractedMetadata.rating,
            ),
        )
        metadata.sourceID = sourceRecordValue.id
        metadata.source = sourceRecordValue.name

        let effectiveCategory: LocalMediaCategory
        if metadata.hasAvailableReadaloud {
            effectiveCategory = .synced
        } else if metadata.hasAvailableAudiobook {
            effectiveCategory = .audio
        } else {
            effectiveCategory = category
        }

        let bookFolder =
            existingBookFolder(for: metadata.uuid)
            ?? resolved.url.appendingPathComponent(
                folderName(title: bookName, uuid: metadata.uuid),
                isDirectory: true,
            )
        let destinationDirectory = bookFolder.appendingPathComponent(
            effectiveCategory.rawValue,
            isDirectory: true,
        )
        try await filesystem.ensureDirectoryExists(at: destinationDirectory)

        let destinationURL: URL
        if effectiveCategory == .audio {
            destinationURL = try await importAudiobookPackage(
                from: sourceFileURL,
                to: destinationDirectory,
                title: metadata.title,
            )
        } else {
            destinationURL = destinationDirectory.appendingPathComponent(
                sourceFileURL.lastPathComponent,
                isDirectory: false,
            )
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: sourceFileURL, to: destinationURL)
        }

        _ = try await scanLibrary(in: resolved.url)
        return destinationURL
    }

    public func replaceMedia(
        from sourceFileURL: URL,
        category: LocalMediaCategory,
        bookName: String,
        bookUUID: String,
    ) async throws -> URL {
        if pathCache[bookUUID] == nil {
            _ = await fetchLibraryInformation()
        }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        if let destinationDirectory = existingCategoryDirectory(
            for: bookUUID,
            category: category,
        ) {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationDirectory.path) {
                try fm.removeItem(at: destinationDirectory)
            }
        }

        return try await importMedia(
            from: sourceFileURL,
            category: category,
            bookName: bookName,
            bookUUID: bookUUID,
        )
    }

    public func importAudiobookFiles(
        from sourceFileURLs: [URL],
        bookName: String,
        bookUUID: String? = nil,
    ) async throws -> URL {
        guard let firstSourceURL = sourceFileURLs.first else {
            throw LocalMediaError.importFailed("No audiobook files selected")
        }

        let accessScopes = sourceFileURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, shouldStopAccessing) in accessScopes where shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        let extractedMetadata = try await localLibrary.extractMetadata(
            from: firstSourceURL,
            category: .audio,
        )
        let importUUID = bookUUID ?? extractedMetadata.uuid
        var metadata = mergedBookMetadata(
            scanned: extractedMetadata,
            saved: BookMetadata(
                uuid: importUUID,
                title: extractedMetadata.title,
                subtitle: extractedMetadata.subtitle,
                description: extractedMetadata.description,
                language: extractedMetadata.language,
                createdAt: extractedMetadata.createdAt,
                updatedAt: extractedMetadata.updatedAt,
                publicationDate: extractedMetadata.publicationDate,
                authors: extractedMetadata.authors,
                narrators: extractedMetadata.narrators,
                creators: extractedMetadata.creators,
                series: extractedMetadata.series,
                tags: extractedMetadata.tags,
                collections: extractedMetadata.collections,
                ebook: nil,
                audiobook: extractedMetadata.audiobook,
                readaloud: nil,
                status: extractedMetadata.status,
                position: extractedMetadata.position,
                rating: extractedMetadata.rating,
            ),
        )
        metadata.sourceID = sourceRecordValue.id
        metadata.source = sourceRecordValue.name

        let bookFolder =
            existingBookFolder(for: metadata.uuid)
            ?? resolved.url.appendingPathComponent(
                folderName(title: bookName, uuid: metadata.uuid),
                isDirectory: true,
            )
        let destinationDirectory = bookFolder.appendingPathComponent(
            LocalMediaCategory.audio.rawValue,
            isDirectory: true,
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDirectory.path) {
            try fm.removeItem(at: destinationDirectory)
        }
        try await filesystem.ensureDirectoryExists(at: destinationDirectory)

        var destinationURLs: [URL] = []
        for sourceURL in sourceFileURLs {
            let destinationURL = destinationDirectory.appendingPathComponent(
                sourceURL.lastPathComponent,
                isDirectory: false,
            )
            try fm.copyItem(at: sourceURL, to: destinationURL)
            destinationURLs.append(destinationURL)
        }

        try await writeAudiobookManifest(
            in: destinationDirectory,
            title: metadata.title,
            audioFiles: destinationURLs,
        )
        let manifestURL = destinationDirectory.appendingPathComponent(
            "manifest.json",
            isDirectory: false,
        )

        _ = try await scanLibrary(in: resolved.url)
        return manifestURL
    }

    public func importBookAssets(
        bookUUID: String,
        bookName: String,
        ebook: StorytellerUploadAsset? = nil,
        audiobooks: [StorytellerUploadAsset] = [],
        readaloud: StorytellerUploadAsset? = nil,
    ) async throws {
        guard ebook != nil || !audiobooks.isEmpty || readaloud != nil else {
            throw LocalMediaError.importFailed("No assets selected")
        }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        let bookFolder =
            existingBookFolder(for: bookUUID)
            ?? resolved.url.appendingPathComponent(
                folderName(title: bookName, uuid: bookUUID),
                isDirectory: true,
            )
        try await filesystem.ensureDirectoryExists(at: bookFolder)

        if let ebook {
            _ = try await writeAsset(
                ebook,
                to: bookFolder.appendingPathComponent(LocalMediaCategory.ebook.rawValue),
            )
        }

        if !audiobooks.isEmpty {
            let audioDirectory = bookFolder.appendingPathComponent(
                LocalMediaCategory.audio.rawValue,
                isDirectory: true,
            )
            if FileManager.default.fileExists(atPath: audioDirectory.path) {
                try FileManager.default.removeItem(at: audioDirectory)
            }
            try await filesystem.ensureDirectoryExists(at: audioDirectory)

            var audioFiles: [URL] = []
            var usedFilenames: Set<String> = []
            for audiobook in audiobooks {
                let destinationURL = try await writeAsset(
                    audiobook,
                    to: audioDirectory,
                    usedFilenames: &usedFilenames,
                )
                audioFiles.append(destinationURL)
            }

            try await writeAudiobookManifest(
                in: audioDirectory,
                title: bookName,
                audioFiles: audioFiles,
            )
        }

        if let readaloud {
            _ = try await writeAsset(
                readaloud,
                to: bookFolder.appendingPathComponent(LocalMediaCategory.synced.rawValue),
            )
        }

        _ = try await scanLibrary(in: resolved.url)
    }

    public func commitBulkImport(_ plan: FolderSourceBulkImportPlan) async
        -> FolderSourceBulkImportCommitResult
    {
        var importedCount = 0
        var skippedCount = 0
        var failures: [String] = []

        for group in plan.groups {
            guard group.isSelected else {
                skippedCount += 1
                continue
            }

            let title =
                group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled Book"
                : group.title
            let ebookAssets = group.assets.filter { $0.selectedRole == .ebook }
            let readaloudAssets = group.assets.filter { $0.selectedRole == .readaloud }
            let audiobookAssets = group.assets.filter { $0.selectedRole == .audiobook }

            do {
                if let ebook = ebookAssets.first {
                    _ = try await importMedia(
                        from: ebook.url,
                        category: .ebook,
                        bookName: title,
                        bookUUID: group.bookUUID,
                    )
                }
                if let readaloud = readaloudAssets.first {
                    _ = try await importMedia(
                        from: readaloud.url,
                        category: .synced,
                        bookName: title,
                        bookUUID: group.bookUUID,
                    )
                }
                if !audiobookAssets.isEmpty {
                    _ = try await importAudiobookFiles(
                        from: audiobookAssets.map(\.url).sorted {
                            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                                == .orderedAscending
                        },
                        bookName: title,
                        bookUUID: group.bookUUID,
                    )
                }

                if ebookAssets.isEmpty && readaloudAssets.isEmpty && audiobookAssets.isEmpty {
                    skippedCount += 1
                } else {
                    importedCount += 1
                }
            } catch {
                failures.append("\(title): \(error.localizedDescription)")
            }
        }

        return FolderSourceBulkImportCommitResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            failures: failures,
        )
    }

    public func replaceAsset(
        _ asset: StorytellerUploadAsset,
        bookName: String,
        bookUUID: String,
    ) async throws {
        if pathCache[bookUUID] == nil {
            _ = await fetchLibraryInformation()
        }

        let category = localMediaCategory(for: asset.format)
        if let destinationDirectory = existingCategoryDirectory(
            for: bookUUID,
            category: category,
        ) {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationDirectory.path) {
                try fm.removeItem(at: destinationDirectory)
            }
        }

        switch asset.format {
            case .ebook:
                try await importBookAssets(
                    bookUUID: bookUUID,
                    bookName: bookName,
                    ebook: asset,
                )
            case .audiobook:
                try await importBookAssets(
                    bookUUID: bookUUID,
                    bookName: bookName,
                    audiobooks: [asset],
                )
            case .readaloud:
                try await importBookAssets(
                    bookUUID: bookUUID,
                    bookName: bookName,
                    readaloud: asset,
                )
        }
    }

    public func deleteBook(_ bookID: String) async throws {
        if pathCache[bookID] == nil {
            _ = await fetchLibraryInformation()
        }
        guard let paths = pathCache[bookID] else {
            try await removeMetadata(bookID: bookID)
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

        if let bookFolder, FileManager.default.fileExists(atPath: bookFolder.path) {
            try FileManager.default.removeItem(at: bookFolder)
        }
        try await removeMetadata(bookID: bookID)
    }

    public func deleteMedia(
        _ bookID: String,
        category: LocalMediaCategory,
    ) async throws {
        if pathCache[bookID] == nil {
            _ = await fetchLibraryInformation()
        }
        guard
            let destinationDirectory = existingCategoryDirectory(
                for: bookID,
                category: category,
            )
        else {
            return
        }

        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.removeItem(at: destinationDirectory)
        }

        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }
        _ = try await scanLibrary(in: resolved.url)
    }

    private func scanLibrary() async throws -> LocalLibraryManager.ScanResult {
        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }
        return try await scanLibrary(in: resolved.url)
    }

    private func scanLibrary(in folderURL: URL) async throws -> LocalLibraryManager.ScanResult {
        try await filesystem.ensureDirectoryExists(at: folderURL)
        try await filesystem.ensureSourceIDMarker(in: folderURL, sourceID: sourceRecordValue.id)

        let localScanResult = try await localLibrary.scanLocalMedia(
            folderURL: folderURL,
            sourceID: sourceRecordValue.id,
        )

        let savedMetadata = try await savedMetadata(in: folderURL)
        let savedByUUID = savedMetadataByUUID(savedMetadata)
        var mergedMetadata: [BookMetadata] = []
        var mergedPaths: [String: MediaPaths] = [:]

        for scanned in localScanResult.metadata {
            var merged = mergeSavedState(
                into: scanned,
                saved: savedByUUID[scanned.uuid],
            )
            merged.sourceID = sourceRecordValue.id
            merged.source = sourceRecordValue.name
            mergedMetadata.append(merged)

            if let scannedPaths = localScanResult.paths[scanned.uuid] {
                mergedPaths[scanned.uuid] = scannedPaths
            }
        }

        logDuplicateFolderUUIDs(mergedMetadata, folderURL: folderURL)
        try await filesystem.saveFolderSourceLibraryMetadata(mergedMetadata, in: folderURL)
        metadataCache = mergedMetadata
        pathCache = mergedPaths

        return LocalLibraryManager.ScanResult(metadata: mergedMetadata, paths: mergedPaths)
    }

    private func savedMetadata(in folderURL: URL) async throws -> [BookMetadata] {
        if let folderMetadata = try await filesystem.loadFolderSourceLibraryMetadata(in: folderURL)
        {
            return folderMetadata.map { book in
                var stamped = book
                stamped.sourceID = sourceRecordValue.id
                stamped.source = sourceRecordValue.name
                return stamped
            }
        }

        return []
    }

    private func existingBookFolder(for bookID: String) -> URL? {
        guard let paths = pathCache[bookID] else { return nil }
        let mediaPath = paths.ebookPath ?? paths.audioPath ?? paths.syncedPath
        return mediaPath?.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func existingCategoryDirectory(
        for bookID: String,
        category: LocalMediaCategory,
    ) -> URL? {
        guard let paths = pathCache[bookID] else { return nil }
        let mediaPath: URL?
        switch category {
            case .ebook:
                mediaPath = paths.ebookPath
            case .audio:
                mediaPath = paths.audioPath
            case .synced:
                mediaPath = paths.syncedPath
        }
        return mediaPath?.deletingLastPathComponent()
    }

    private func extractImportMetadata(
        from sourceFileURL: URL,
        category: LocalMediaCategory,
    ) async throws -> BookMetadata {
        guard category == .audio, sourceFileURL.hasDirectoryPath else {
            return try await localLibrary.extractMetadata(
                from: sourceFileURL,
                category: category,
            )
        }

        let bookUUID = UUID().uuidString
        return BookMetadata(
            uuid: bookUUID,
            title: sourceFileURL.lastPathComponent,
            subtitle: nil,
            description: nil,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: nil,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: nil,
            audiobook: BookAsset(
                uuid: bookUUID,
                filepath: "manifest.json",
                missing: 0,
                createdAt: nil,
                updatedAt: nil,
            ),
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }

    private func importAudiobookPackage(
        from sourceURL: URL,
        to destinationDirectory: URL,
        title: String,
    ) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDirectory.path) {
            try fm.removeItem(at: destinationDirectory)
        }
        try await filesystem.ensureDirectoryExists(at: destinationDirectory)

        if sourceURL.lastPathComponent == "manifest.json" {
            try copyDirectoryContents(
                from: sourceURL.deletingLastPathComponent(),
                to: destinationDirectory,
            )
        } else if sourceURL.hasDirectoryPath {
            try copyDirectoryContents(from: sourceURL, to: destinationDirectory)
        } else {
            let destinationURL = destinationDirectory.appendingPathComponent(
                sourceURL.lastPathComponent,
                isDirectory: false,
            )
            try fm.copyItem(at: sourceURL, to: destinationURL)
        }

        let manifestURL = destinationDirectory.appendingPathComponent(
            "manifest.json",
            isDirectory: false,
        )
        if !fm.fileExists(atPath: manifestURL.path) {
            try await writeAudiobookManifest(in: destinationDirectory, title: title)
        }

        return manifestURL
    }

    private func copyDirectoryContents(from sourceDirectory: URL, to destinationDirectory: URL)
        throws
    {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        for item in contents {
            let destinationURL = destinationDirectory.appendingPathComponent(
                item.lastPathComponent,
                isDirectory: item.hasDirectoryPath,
            )
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: item, to: destinationURL)
        }
    }

    private func writeAudiobookManifest(
        in audioDirectory: URL,
        title: String,
        audioFiles orderedAudioFiles: [URL]? = nil,
    ) async throws {
        let audioFiles: [URL]
        if let orderedAudioFiles {
            audioFiles = orderedAudioFiles
        } else {
            audioFiles = try audiobookMediaFiles(in: audioDirectory)
        }
        guard !audioFiles.isEmpty else {
            throw LocalMediaError.missingAudiobookManifest
        }

        var readingOrder: [[String: Any]] = []
        var totalDuration = 0.0
        for audioFile in audioFiles {
            var item: [String: Any] = [
                "href": audioFile.lastPathComponent,
                "type": mediaType(for: audioFile),
            ]
            if let duration = await audioDuration(for: audioFile) {
                item["duration"] = duration
                totalDuration += duration
            }
            readingOrder.append(item)
        }

        var metadata: [String: Any] = [
            "@type": "http://schema.org/Audiobook",
            "title": title,
        ]
        if totalDuration > 0 {
            metadata["duration"] = totalDuration
        }

        let manifest: [String: Any] = [
            "metadata": metadata,
            "links": [
                [
                    "rel": "self",
                    "href": "manifest.json",
                    "type": "application/audiobook+json",
                ]
            ],
            "readingOrder": readingOrder,
            "toc": readingOrder.enumerated().map { index, item in
                [
                    "href": "\(item["href"] ?? "")#t=0",
                    "title": audioFiles.count == 1 ? "Full Book" : "Track \(index + 1)",
                ]
            },
        ]

        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys],
        )
        try data.write(
            to: audioDirectory.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic,
        )
    }

    private func writeAsset(
        _ asset: StorytellerUploadAsset,
        to destinationDirectory: URL,
        usedFilenames: inout Set<String>,
    ) async throws -> URL {
        try await filesystem.ensureDirectoryExists(at: destinationDirectory)
        let filename = uniqueFilename(preferredFilename(for: asset), usedFilenames: &usedFilenames)
        let destinationURL = destinationDirectory.appendingPathComponent(
            filename,
            isDirectory: false,
        )
        try asset.data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func writeAsset(
        _ asset: StorytellerUploadAsset,
        to destinationDirectory: URL,
    ) async throws -> URL {
        var usedFilenames: Set<String> = []
        return try await writeAsset(asset, to: destinationDirectory, usedFilenames: &usedFilenames)
    }

    private func preferredFilename(for asset: StorytellerUploadAsset) -> String {
        let fallback = "\(asset.format.rawValue).\(defaultExtension(for: asset))"
        let filename = asset.filename.isEmpty ? fallback : asset.filename
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        return lastPathComponent.isEmpty ? fallback : lastPathComponent
    }

    private func uniqueFilename(_ filename: String, usedFilenames: inout Set<String>) -> String {
        guard usedFilenames.contains(filename) else {
            usedFilenames.insert(filename)
            return filename
        }

        let url = URL(fileURLWithPath: filename)
        let basename = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        var index = 2
        while true {
            let candidate =
                pathExtension.isEmpty
                ? "\(basename) \(index)"
                : "\(basename) \(index).\(pathExtension)"
            if !usedFilenames.contains(candidate) {
                usedFilenames.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    private func localMediaCategory(for format: StorytellerBookFormat) -> LocalMediaCategory {
        switch format {
            case .ebook:
                return .ebook
            case .audiobook:
                return .audio
            case .readaloud:
                return .synced
        }
    }

    private func defaultExtension(for asset: StorytellerUploadAsset) -> String {
        switch asset.format {
            case .ebook, .readaloud:
                return "epub"
            case .audiobook:
                return asset.contentType == "audio/mp4" ? "m4b" : "mp3"
        }
    }

    private func audiobookMediaFiles(in audioDirectory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        return
            contents
            .filter { url in
                guard url.lastPathComponent != "manifest.json",
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                else {
                    return false
                }
                return audiobookMediaExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    private var audiobookMediaExtensions: Set<String> {
        ["aac", "flac", "m4a", "m4b", "mp3", "ogg", "opus", "wav"]
    }

    private func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
            case "aac":
                return "audio/aac"
            case "flac":
                return "audio/flac"
            case "m4a", "m4b":
                return "audio/mp4"
            case "mp3":
                return "audio/mpeg"
            case "ogg", "opus":
                return "audio/ogg"
            case "wav":
                return "audio/wav"
            default:
                return "application/octet-stream"
        }
    }

    private func audioDuration(for url: URL) async -> Double? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
        #else
        return nil
        #endif
    }

    private func createAudiobookArchive(from packageDirectory: URL, at archiveURL: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)

        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: packageDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )
        else {
            throw LocalMediaError.importFailed("Could not read audiobook package")
        }

        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            else {
                continue
            }
            let relativePath = try audiobookArchiveEntryPath(
                for: file,
                relativeTo: packageDirectory,
            )
            try archive.addEntry(
                with: relativePath,
                relativeTo: packageDirectory,
            )
        }
    }

    private func audiobookArchiveEntryPath(for file: URL, relativeTo packageDirectory: URL) throws
        -> String
    {
        let baseComponents = packageDirectory.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw LocalMediaError.importFailed(
                "Audiobook package file is outside its source folder"
            )
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private func savedMetadataByUUID(_ metadata: [BookMetadata]) -> [String: BookMetadata] {
        var savedByUUID: [String: BookMetadata] = [:]
        for saved in metadata {
            if savedByUUID[saved.uuid] != nil {
                debugLog(
                    "[FolderSourceActor] Duplicate saved metadata UUID \(saved.uuid) in \(sourceRecordValue.name)"
                )
                continue
            }
            savedByUUID[saved.uuid] = saved
        }
        return savedByUUID
    }

    private func mergeSavedState(
        into scanned: BookMetadata,
        saved: BookMetadata?,
    ) -> BookMetadata {
        guard let saved else { return scanned }
        return metadata(
            scanned,
            status: saved.status,
            position: saved.position,
        )
    }

    private func logDuplicateFolderUUIDs(_ metadata: [BookMetadata], folderURL: URL) {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for book in metadata {
            if seen.contains(book.uuid) {
                duplicates.insert(book.uuid)
            } else {
                seen.insert(book.uuid)
            }
        }
        guard !duplicates.isEmpty else { return }
        debugLog(
            "[FolderSourceActor] Duplicate book UUIDs in folder source \(sourceRecordValue.name) at \(folderURL.path): \(duplicates.sorted().joined(separator: ", "))"
        )
    }

    private func updateBookProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async throws {
        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        if metadataCache.isEmpty {
            _ = try await scanLibrary(in: resolved.url)
        }

        var latestMetadata = try await savedMetadata(in: resolved.url)
        guard let latestIndex = latestMetadata.firstIndex(where: { $0.uuid == bookId }) else {
            return
        }
        let latest = latestMetadata[latestIndex]
        let latestTimestamp = latest.position?.timestamp ?? 0
        guard timestamp > latestTimestamp else { return }

        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()
        let newPosition = BookReadingPosition(
            uuid: latest.position?.uuid,
            locator: locator,
            timestamp: timestamp,
            createdAt: latest.position?.createdAt,
            updatedAt: updatedAtString,
        )
        latestMetadata[latestIndex] = metadata(latest, position: newPosition)
        metadataCache = latestMetadata
        try await filesystem.saveFolderSourceLibraryMetadata(latestMetadata, in: resolved.url)
    }

    private func removeMetadata(bookID: String) async throws {
        let resolved = try await resolvedFolderURL()
        defer { stopAccessing(resolved) }

        metadataCache.removeAll { $0.uuid == bookID }
        pathCache.removeValue(forKey: bookID)
        try await filesystem.saveFolderSourceLibraryMetadata(metadataCache, in: resolved.url)
    }

    private func extractCover(for bookID: String) async -> Data? {
        if pathCache[bookID] == nil {
            _ = await fetchLibraryInformation()
        }
        guard let paths = pathCache[bookID] else { return nil }

        if let ebookPath = paths.ebookPath,
            let data = localLibrary.extractCoverFromEpub(at: ebookPath)
        {
            return data
        }

        if let syncedPath = paths.syncedPath,
            let data = localLibrary.extractCoverFromEpub(at: syncedPath)
        {
            return data
        }

        if let audioPath = paths.audioPath,
            let data = await localLibrary.extractCoverFromAudiobook(at: audioPath)
        {
            return data
        }

        return nil
    }

    private func resolvedFolderURL() async throws -> (
        url: URL,
        didStartAccessing: Bool
    ) {
        await SilveranMigrations.ensureMigrationsRan()
        if let resolved = sourceFolderURL(sourceRecordValue) {
            try await filesystem.ensureDirectoryExists(at: resolved.url)
            return resolved
        }

        throw LocalMediaError.importFailed("Folder source has no storage location")
    }

    private func sourceFolderURL(_ sourceRecord: BookSourceRecord) -> (
        url: URL,
        didStartAccessing: Bool
    )? {
        #if os(macOS)
        if let bookmarkData = sourceRecord.storageBookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            ) {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                return (url, didStartAccessing)
            }
        }
        #elseif os(iOS)
        if let bookmarkData = sourceRecord.storageBookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            ) {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                return (url, didStartAccessing)
            }
        }
        #endif

        guard let storagePath = sourceRecord.storagePath, !storagePath.isEmpty else {
            return nil
        }
        return (URL(fileURLWithPath: storagePath, isDirectory: true), false)
    }

    private func stopAccessing(_ resolved: (url: URL, didStartAccessing: Bool)) {
        if resolved.didStartAccessing {
            resolved.url.stopAccessingSecurityScopedResource()
        }
    }

    private func folderName(title: String, uuid: String) -> String {
        let sanitizedTitle = sanitizedPathComponent(title)
        let sanitizedUUID = sanitizedPathComponent(uuid)
        guard !sanitizedTitle.isEmpty else { return sanitizedUUID.isEmpty ? "Book" : sanitizedUUID }
        guard !sanitizedUUID.isEmpty else { return sanitizedTitle }
        if sanitizedTitle.caseInsensitiveCompare(sanitizedUUID) == .orderedSame {
            return sanitizedTitle
        }
        return "\(sanitizedTitle) - \(sanitizedUUID)"
    }

    private func sanitizedPathComponent(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized =
            input
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Book" : sanitized
    }

    private func metadata(
        _ existing: BookMetadata,
        status: BookStatus? = nil,
        position: BookReadingPosition? = nil,
    ) -> BookMetadata {
        var updated = BookMetadata(
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
            status: status ?? existing.status,
            position: position ?? existing.position,
            rating: existing.rating,
        )
        updated.alignedAt = existing.alignedAt
        updated.alignedByStorytellerVersion = existing.alignedByStorytellerVersion
        updated.alignedWith = existing.alignedWith
        updated.sourceID = sourceRecordValue.id
        updated.source = sourceRecordValue.name
        return updated
    }

    private func mergedBookMetadata(
        scanned: BookMetadata,
        saved: BookMetadata,
        position: BookReadingPosition? = nil,
    ) -> BookMetadata {
        BookMetadata(
            uuid: saved.uuid,
            title: scanned.title,
            subtitle: scanned.subtitle,
            description: scanned.description,
            language: scanned.language,
            createdAt: saved.createdAt,
            updatedAt: saved.updatedAt,
            publicationDate: scanned.publicationDate,
            authors: scanned.authors,
            narrators: scanned.narrators,
            creators: scanned.creators,
            series: scanned.series,
            tags: scanned.tags,
            collections: scanned.collections,
            ebook: scanned.ebook.map { asset in
                BookAsset(
                    uuid: saved.uuid,
                    filepath: asset.filepath,
                    missing: asset.missing,
                    createdAt: asset.createdAt,
                    updatedAt: asset.updatedAt,
                )
            },
            audiobook: scanned.audiobook.map { asset in
                BookAsset(
                    uuid: saved.uuid,
                    filepath: asset.filepath,
                    missing: asset.missing,
                    createdAt: asset.createdAt,
                    updatedAt: asset.updatedAt,
                )
            },
            readaloud: scanned.readaloud.map { asset in
                BookReadaloud(
                    uuid: saved.uuid,
                    filepath: asset.filepath,
                    missing: asset.missing,
                    status: asset.status,
                    currentStage: asset.currentStage,
                    stageProgress: asset.stageProgress,
                    queuePosition: asset.queuePosition,
                    restartPending: asset.restartPending,
                    createdAt: asset.createdAt,
                    updatedAt: asset.updatedAt,
                )
            },
            status: saved.status,
            position: position ?? saved.position,
            rating: saved.rating,
        )
    }
}
