import Dispatch
import Foundation
import ZIPFoundation

/// Handles filesystem storage for local media, including directory management and metadata persistence.
public actor FilesystemActor {
    public static let shared = FilesystemActor()
    private let ioQueue = DispatchQueue(label: "FilesystemActor.ioQueue", qos: .utility)
    private var pendingQueueWriteTask: Task<Void, Error>?
    private var pendingQueueWriteId: Int = 0
    private var pendingHistoryWriteTask: Task<Void, Error>?
    private var pendingHistoryWriteId: Int = 0

    public init() {}

    public func ensureLocalStorageDirectories() throws {
        try ensureDirectoryExists(at: sourceCacheRootDirectory())
        try ensureDirectoryExists(at: derivedMediaRootDirectory())
    }

    public func sourceCacheRootDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("SourceCache", isDirectory: true)
    }

    public func derivedMediaRootDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("DerivedMedia", isDirectory: true)
    }

    public func epubExtractionRootDirectory() -> URL {
        derivedMediaRootDirectory()
            .appendingPathComponent("EPUBExtraction", isDirectory: true)
    }

    public func folderSourceDerivedAudiobookRootDirectory(sourceID: BookSourceID) -> URL {
        derivedMediaRootDirectory()
            .appendingPathComponent("FolderSourceAudiobooks", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(from: sourceID), isDirectory: true)
    }

    public func folderSourceDerivedAudiobookDirectory(
        sourceID: BookSourceID,
        bookID: String,
    ) -> URL {
        folderSourceDerivedAudiobookRootDirectory(sourceID: sourceID)
            .appendingPathComponent(sanitizedPathComponent(from: bookID), isDirectory: true)
    }

    public func removeFolderSourceDerivedAudiobooks(sourceID: BookSourceID) throws {
        let directory = folderSourceDerivedAudiobookRootDirectory(sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func sourceCacheDirectory(sourceID: BookSourceID) -> URL {
        return sourceCacheRootDirectory()
            .appendingPathComponent(sanitizedPathComponent(from: sourceID), isDirectory: true)
    }

    public func internalFolderSourceRootDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("InternalFolderSource", isDirectory: true)
    }

    public func internalFolderSourceDirectory() -> URL {
        internalFolderSourceRootDirectory()
    }

    public nonisolated func whisperModelsDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    public func ensureInternalFolderSourceDirectory(sourceID: BookSourceID) throws -> URL {
        let directory = internalFolderSourceDirectory()
        try ensureSourceIDMarker(in: directory, sourceID: sourceID)
        return directory
    }

    public func sourceIDMarker(in directory: URL) throws -> BookSourceID? {
        let marker = directory.appendingPathComponent(
            BookSourceRecord.sourceIDFilename,
            isDirectory: false,
        )
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return nil
        }
        let sourceID = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceID.isEmpty ? nil : sourceID
    }

    public func ensureSourceIDMarker(in directory: URL, sourceID: BookSourceID) throws {
        try ensureDirectoryExists(at: directory)
        let marker = directory.appendingPathComponent(
            BookSourceRecord.sourceIDFilename,
            isDirectory: false,
        )
        try sourceID.write(to: marker, atomically: true, encoding: .utf8)
    }

    public func getMediaDirectory(
        category: LocalMediaCategory,
        bookName: String,
        uuidIdentifier: String? = nil,
        sourceID: BookSourceID,
    ) async -> URL {
        let cacheDirectory = sourceCacheDirectory(sourceID: sourceID)
        let folderName = await resolveBookFolderName(
            in: cacheDirectory,
            bookName: bookName,
            uuidIdentifier: uuidIdentifier,
        )
        return
            cacheDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
    }

    public func resolveBookFolderName(
        in sourceDirectory: URL,
        bookName: String,
        uuidIdentifier: String?,
    ) async -> String {
        let sanitizedBase = sanitizedPathComponent(from: bookName)
        let uuidSanitized: String? = {
            guard let uuidIdentifier else { return nil }
            let sanitized = sanitizedPathComponent(from: uuidIdentifier)
            return sanitized.isEmpty ? nil : sanitized
        }()

        if let uuidSanitized {
            if let existing = try? await existingFolder(
                matching: uuidSanitized,
                in: sourceDirectory,
            ) {
                return existing
            }

            if sanitizedBase.isEmpty {
                return uuidSanitized
            }

            if sanitizedBase.caseInsensitiveCompare(uuidSanitized) == .orderedSame {
                return sanitizedBase
            }

            return "\(sanitizedBase) - \(uuidSanitized)"
        }

        let baseForLocal = sanitizedBase.isEmpty ? "Book" : sanitizedBase
        return baseForLocal
    }

    public func mediaDirectory(
        for uuid: String,
        category: LocalMediaCategory,
        sourceID: BookSourceID,
    ) async -> URL? {
        let sourceDirectory = sourceCacheDirectory(sourceID: sourceID)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: sourceDirectory,
            )
        else {
            return nil
        }

        let categoryDir =
            sourceDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: categoryDir.path) else { return nil }
        return categoryDir
    }

    public func deleteMedia(
        for uuid: String,
        category: LocalMediaCategory,
        sourceID: BookSourceID,
    ) async throws {
        let sourceDirectory = sourceCacheDirectory(sourceID: sourceID)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: sourceDirectory,
            )
        else {
            return
        }

        let categoryDir =
            sourceDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)

        let fm = FileManager.default
        if fm.fileExists(atPath: categoryDir.path) {
            try fm.removeItem(at: categoryDir)
        }
    }

    public func ensureDirectoryExists(at url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func saveSourceCacheLibraryMetadata(
        _ metadata: [BookMetadata],
        sourceID: BookSourceID,
    ) throws {
        let cacheDir = sourceCacheDirectory(sourceID: sourceID)
        try ensureDirectoryExists(at: cacheDir)

        let metadataURL = cacheDir.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try write(data: data, to: metadataURL)
    }

    public func loadSourceCacheLibraryMetadata(sourceID: BookSourceID) throws -> [BookMetadata]? {
        try loadLibraryMetadata(in: sourceCacheDirectory(sourceID: sourceID))
    }

    public func saveDownloadedMediaLedger(
        _ ledger: [String: DownloadedMediaRecord],
        sourceID: BookSourceID,
    ) throws {
        let cacheDir = sourceCacheDirectory(sourceID: sourceID)
        try ensureDirectoryExists(at: cacheDir)
        let ledgerURL = cacheDir.appendingPathComponent(
            "downloaded_media.json",
            isDirectory: false,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        try write(data: data, to: ledgerURL)
    }

    public func loadDownloadedMediaLedger(
        sourceID: BookSourceID
    ) throws -> [String: DownloadedMediaRecord]? {
        let ledgerURL = sourceCacheDirectory(sourceID: sourceID)
            .appendingPathComponent("downloaded_media.json", isDirectory: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: ledgerURL.path) else { return nil }
        let data = try Data(contentsOf: ledgerURL)
        return try JSONDecoder().decode([String: DownloadedMediaRecord].self, from: data)
    }

    private func loadLibraryMetadata(in directory: URL) throws -> [BookMetadata]? {
        let metadataURL = directory.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode([BookMetadata].self, from: data)
    }

    public func saveFolderSourceLibraryState(_ state: FolderSourceLibraryState, in directory: URL)
        throws
    {
        try ensureDirectoryExists(at: directory)
        let metadataURL = directory.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try write(data: data, to: metadataURL)
    }

    public func loadFolderSourceLibraryState(in directory: URL) throws -> FolderSourceLibraryState?
    {
        let metadataURL = directory.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode(FolderSourceLibraryState.self, from: data)
    }

    public func getConfigDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("Config", isDirectory: true)
    }

    public func saveBookSources(_ sources: [BookSourceRecord]) throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let sourcesURL = configDir.appendingPathComponent(
            "book_sources.json",
            isDirectory: false,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        try write(data: data, to: sourcesURL)
    }

    public func loadBookSources() async throws -> [BookSourceRecord]? {
        let sourcesURL = getConfigDirectory().appendingPathComponent(
            "book_sources.json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcesURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        let data = try Data(contentsOf: sourcesURL)
        let sources = try decoder.decode([BookSourceRecord].self, from: data)
        return sources
    }

    public func loadOrCreateBookSources() async throws -> [BookSourceRecord] {
        if let sources = try await loadBookSources(), !sources.isEmpty {
            return sources
        }

        return try createDefaultBookSources()
    }

    public func loadProgressQueue() async throws -> [PendingProgressSync] {
        await waitForPendingQueueWrite()
        let configDir = getConfigDirectory()
        let queueURL = configDir.appendingPathComponent(
            "offline_progress_queue.json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: queueURL.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: queueURL)
        return try decoder.decode([PendingProgressSync].self, from: data)
    }

    public func saveProgressQueue(_ queue: [PendingProgressSync]) async throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let queueURL = configDir.appendingPathComponent(
            "offline_progress_queue.json",
            isDirectory: false,
        )
        let tempURL = configDir.appendingPathComponent(
            "offline_progress_queue.tmp",
            isDirectory: false,
        )
        let queueSnapshot = queue
        let writeId = pendingQueueWriteId + 1
        pendingQueueWriteId = writeId
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.async {
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(queueSnapshot)
                        try data.write(to: tempURL, options: .atomic)

                        let fm = FileManager.default
                        if fm.fileExists(atPath: queueURL.path) {
                            try fm.removeItem(at: queueURL)
                        }
                        try fm.moveItem(at: tempURL, to: queueURL)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        pendingQueueWriteTask = task

        defer {
            if pendingQueueWriteId == writeId {
                pendingQueueWriteTask = nil
            }
        }

        try await task.value
    }

    public func loadSyncHistory() async throws -> [String: [SyncHistoryEntry]] {
        await waitForPendingHistoryWrite()
        let configDir = getConfigDirectory()
        let historyURL = configDir.appendingPathComponent(
            "sync_history.json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: historyURL.path) else {
            return [:]
        }

        let decoder = JSONDecoder()
        let data = try Data(contentsOf: historyURL)
        return try decoder.decode([String: [SyncHistoryEntry]].self, from: data)
    }

    public func saveSyncHistory(_ history: [String: [SyncHistoryEntry]]) async throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let historyURL = configDir.appendingPathComponent(
            "sync_history.json",
            isDirectory: false,
        )
        let tempURL = configDir.appendingPathComponent(
            "sync_history.tmp",
            isDirectory: false,
        )
        let historySnapshot = history
        let writeId = pendingHistoryWriteId + 1
        pendingHistoryWriteId = writeId
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.async {
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let data = try encoder.encode(historySnapshot)
                        try data.write(to: tempURL, options: .atomic)

                        let fm = FileManager.default
                        if fm.fileExists(atPath: historyURL.path) {
                            try fm.removeItem(at: historyURL)
                        }
                        try fm.moveItem(at: tempURL, to: historyURL)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        pendingHistoryWriteTask = task

        defer {
            if pendingHistoryWriteId == writeId {
                pendingHistoryWriteTask = nil
            }
        }

        try await task.value
    }

    private func waitForPendingQueueWrite() async {
        while let task = pendingQueueWriteTask {
            let currentId = pendingQueueWriteId
            _ = try? await task.value
            if pendingQueueWriteId == currentId {
                break
            }
        }
    }

    private func waitForPendingHistoryWrite() async {
        while let task = pendingHistoryWriteTask {
            let currentId = pendingHistoryWriteId
            _ = try? await task.value
            if pendingHistoryWriteId == currentId {
                break
            }
        }
    }

    public func saveCoverImage(uuid: String, data: Data, variant: String) throws {
        let coversDir = coversCacheDirectory()
        try ensureDirectoryExists(at: coversDir)

        let filename = "\(uuid)_\(variant).dat"
        let coverURL = coversDir.appendingPathComponent(filename, isDirectory: false)
        try write(data: data, to: coverURL)
    }

    public func loadCoverImage(uuid: String, variant: String) -> Data? {
        let coversDir = coversCacheDirectory()
        let filename = "\(uuid)_\(variant).dat"
        let coverURL = coversDir.appendingPathComponent(filename, isDirectory: false)
        let fm = FileManager.default

        guard fm.fileExists(atPath: coverURL.path) else {
            return nil
        }

        return try? Data(contentsOf: coverURL)
    }

    public func removeAllCoverImages() throws {
        let coversDir = coversCacheDirectory()
        let fm = FileManager.default

        if fm.fileExists(atPath: coversDir.path) {
            try fm.removeItem(at: coversDir)
        }
    }

    public func removeCoverImages(uuid: String) throws {
        let coversDir = coversCacheDirectory()
        let fm = FileManager.default

        guard
            let contents = try? fm.contentsOfDirectory(
                at: coversDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
        else {
            return
        }

        let sanitizedUUID = sanitizedPathComponent(from: uuid)
        for url in contents
        where url.lastPathComponent == "\(sanitizedUUID).dat"
            || url.lastPathComponent.hasPrefix("\(sanitizedUUID)_")
        {
            try fm.removeItem(at: url)
        }
    }

    private func coversCacheDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("CoversCache", isDirectory: true)
    }

    public func removeSourceCacheBookData(
        uuid: String,
        sourceID: BookSourceID,
    ) async throws {
        let cacheDir = sourceCacheDirectory(sourceID: sourceID)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: cacheDir,
            )
        else {
            try removeCoverImages(uuid: uuid)
            return
        }

        let bookRoot = cacheDir.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: bookRoot.path) {
            try fm.removeItem(at: bookRoot)
        }
        try removeCoverImages(uuid: uuid)
    }

    public func getHighlightsDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("Highlights", isDirectory: true)
    }

    public func loadHighlights(bookId: String) throws -> [Highlight]? {
        let highlightsDir = getHighlightsDirectory()
        let sanitizedBookId = bookId.replacingOccurrences(of: "/", with: "_")
        let fileURL = highlightsDir.appendingPathComponent(
            "\(sanitizedBookId).json",
            isDirectory: false,
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: fileURL)
        let bookHighlights = try decoder.decode(BookHighlights.self, from: data)
        return bookHighlights.highlights
    }

    public func saveHighlights(bookId: String, highlights: [Highlight]) throws {
        let highlightsDir = getHighlightsDirectory()
        try ensureDirectoryExists(at: highlightsDir)

        let sanitizedBookId = bookId.replacingOccurrences(of: "/", with: "_")
        let fileURL = highlightsDir.appendingPathComponent(
            "\(sanitizedBookId).json",
            isDirectory: false,
        )

        let bookHighlights = BookHighlights(bookId: bookId, highlights: highlights)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bookHighlights)

        let tempURL = highlightsDir.appendingPathComponent(
            "\(sanitizedBookId).tmp",
            isDirectory: false,
        )
        try data.write(to: tempURL, options: .atomic)

        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        try fm.moveItem(at: tempURL, to: fileURL)
    }

    public func deleteHighlights(bookId: String) throws {
        let highlightsDir = getHighlightsDirectory()
        let sanitizedBookId = bookId.replacingOccurrences(of: "/", with: "_")
        let fileURL = highlightsDir.appendingPathComponent(
            "\(sanitizedBookId).json",
            isDirectory: false,
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    private func existingFolder(
        matching uuidSanitized: String,
        in domainDirectory: URL,
    ) async throws -> String? {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: domainDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )

        let lowercasedUUID = uuidSanitized.lowercased()
        let exactSuffix = " - \(lowercasedUUID)"

        for url in contents {
            guard
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true
            else {
                continue
            }

            let folderName = url.lastPathComponent
            if folderName.caseInsensitiveCompare(uuidSanitized) == .orderedSame {
                return folderName
            }

            let lowerFolder = folderName.lowercased()
            if lowerFolder.hasSuffix(exactSuffix) {
                return folderName
            }

            if let range = lowerFolder.range(of: exactSuffix + " ") {
                let suffixRemainder = lowerFolder[range.upperBound...]
                let allowed = CharacterSet.decimalDigits.union(.whitespaces)
                if suffixRemainder.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                    return folderName
                }
            }
        }

        return nil
    }

    private func sanitizedPathComponent(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var result = ""
        result.reserveCapacity(trimmed.count)
        var lastWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            if allowed.contains(scalar) {
                let character = Character(scalar)
                if character.isWhitespace {
                    if !lastWasSeparator && !result.isEmpty {
                        result.append(" ")
                        lastWasSeparator = true
                    }
                } else {
                    result.append(character)
                    lastWasSeparator = false
                }
            } else {
                if !lastWasSeparator && !result.isEmpty {
                    result.append(" ")
                    lastWasSeparator = true
                }
            }
        }

        let sanitized = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > 120 {
            let endIndex = sanitized.index(sanitized.startIndex, offsetBy: 120)
            return String(sanitized[..<endIndex])
        }
        return sanitized
    }

    private func write(data: Data, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
    }

    public func getWebResourcesDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("WebResources", isDirectory: true)
    }

    public func copyWebResourcesFromBundle() throws {
        let webResourcesDir = getWebResourcesDirectory()

        let fm = FileManager.default
        if fm.fileExists(atPath: webResourcesDir.path) {
            try fm.removeItem(at: webResourcesDir)
        }

        try ensureDirectoryExists(at: webResourcesDir)

        guard
            let htmlURL = Bundle.main.url(
                forResource: "foliate_wrap",
                withExtension: "html",
                subdirectory: "WebResources",
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find foliate_wrap.html in bundle"],
            )
        }

        guard
            let foliateJSURL = Bundle.main.url(
                forResource: "foliate-js",
                withExtension: nil,
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find foliate-js folder in bundle"],
            )
        }

        let htmlDestination = webResourcesDir.appendingPathComponent("foliate_wrap.html")
        if fm.fileExists(atPath: htmlDestination.path) {
            try fm.removeItem(at: htmlDestination)
        }
        try fm.copyItem(at: htmlURL, to: htmlDestination)

        let foliateJSDestination = webResourcesDir.appendingPathComponent(
            "foliate-js",
            isDirectory: true,
        )
        if fm.fileExists(atPath: foliateJSDestination.path) {
            try fm.removeItem(at: foliateJSDestination)
        }
        try fm.copyItem(at: foliateJSURL, to: foliateJSDestination)

        guard
            let jsFileURLs = Bundle.main.urls(
                forResourcesWithExtension: "js",
                subdirectory: "WebResources",
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find any .js files in bundle"],
            )
        }

        for jsURL in jsFileURLs {
            let fileName = jsURL.lastPathComponent
            let destination = webResourcesDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: jsURL, to: destination)
        }
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "wav", "ogg", "opus", "aac", "flac",
    ]

    public func cleanupExtractedEpubDirectories() {
        let fm = FileManager.default
        var cleanedCount = 0

        guard
            let sourceDirectories = try? fm.contentsOfDirectory(
                at: sourceCacheRootDirectory(),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )
        else { return }

        for sourceDirectory in sourceDirectories {
            guard
                let sourceValues = try? sourceDirectory.resourceValues(forKeys: [.isDirectoryKey]),
                sourceValues.isDirectory == true
            else { continue }

            guard
                let bookFolders = try? fm.contentsOfDirectory(
                    at: sourceDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles],
                )
            else { continue }

            for bookFolder in bookFolders {
                guard let values = try? bookFolder.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                else { continue }

                for category in LocalMediaCategory.allCases {
                    let extractedDir =
                        bookFolder
                        .appendingPathComponent(category.rawValue, isDirectory: true)
                        .appendingPathComponent("extracted", isDirectory: true)

                    if fm.fileExists(atPath: extractedDir.path) {
                        do {
                            try fm.removeItem(at: extractedDir)
                            cleanedCount += 1
                        } catch {
                            debugLog(
                                "[FilesystemActor] Failed to clean up extracted dir: \(extractedDir.path) - \(error)"
                            )
                        }
                    }
                }
            }
        }

        if cleanedCount > 0 {
            debugLog("[FilesystemActor] Cleaned up \(cleanedCount) extracted EPUB directories")
        }
    }

    public func prepareEpubForReading(
        epubPath: URL,
        sourceID: BookSourceID,
        bookID: String,
        category: LocalMediaCategory,
        sizeThresholdMB: Int = 200,
        forceExtract: Bool = false,
    ) async throws -> (url: URL, isExtracted: Bool) {
        let fm = FileManager.default
        let fileSize = try fm.attributesOfItem(atPath: epubPath.path)[.size] as? Int ?? 0
        let fileSizeMB = fileSize / (1024 * 1024)
        let shouldExtract = forceExtract || fileSizeMB > sizeThresholdMB

        guard shouldExtract else {
            return (epubPath, false)
        }

        let extractionDir = derivedEpubExtractionDirectory(
            epubPath: epubPath,
            sourceID: sourceID,
            bookID: bookID,
            category: category,
        )
        let url = try await extractEpubIfNeeded(
            epubPath: epubPath,
            extractedDir: extractionDir,
            sizeThresholdMB: sizeThresholdMB,
            forceExtract: forceExtract,
        )
        return (url, true)
    }

    private func extractEpubIfNeeded(
        epubPath: URL,
        extractedDir: URL,
        sizeThresholdMB: Int,
        forceExtract: Bool,
    ) async throws -> URL {
        let fm = FileManager.default

        let fileSize = try fm.attributesOfItem(atPath: epubPath.path)[.size] as? Int ?? 0
        let fileSizeMB = fileSize / (1024 * 1024)

        let shouldExtract = forceExtract || fileSizeMB > sizeThresholdMB

        if !shouldExtract {
            return epubPath
        }

        let reason = forceExtract ? "native audio playback" : "large file (\(fileSizeMB)MB)"
        debugLog("[FilesystemActor] Extracting EPUB for \(reason)...")

        let sizesFile = extractedDir.appendingPathComponent("_sizes.json")
        if fm.fileExists(atPath: extractedDir.path) {
            if fm.fileExists(atPath: sizesFile.path) {
                debugLog(
                    "[FilesystemActor] Extracted directory already exists and complete, reusing: \(extractedDir.path)"
                )
                return URL(fileURLWithPath: extractedDir.path, isDirectory: true)
            } else {
                debugLog(
                    "[FilesystemActor] Extracted directory exists but incomplete, removing: \(extractedDir.path)"
                )
                try? fm.removeItem(at: extractedDir)
            }
        }

        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)

        debugLog("[FilesystemActor] Extracting EPUB to: \(extractedDir.path)")

        let archive: Archive
        do {
            archive = try Archive(url: epubPath, accessMode: .read)
        } catch {
            throw NSError(
                domain: "FilesystemActor",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to open EPUB archive: \(epubPath.path) - \(error)"
                ],
            )
        }

        var skippedAudioFiles = 0
        var skippedErrors = 0
        var fileSizes: [String: UInt64] = [:]

        for entry in archive {
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            if Self.audioExtensions.contains(ext) {
                skippedAudioFiles += 1
                continue
            }

            let destinationURL = extractedDir.appendingPathComponent(entry.path)
            do {
                _ = try archive.extract(entry, to: destinationURL)
                fileSizes[entry.path] = entry.uncompressedSize
            } catch {
                debugLog(
                    "[FilesystemActor] Skipping file due to extraction error: \(entry.path) - \(error.localizedDescription)"
                )
                skippedErrors += 1
            }
        }

        let sizesURL = extractedDir.appendingPathComponent("_sizes.json")
        let sizesData = try JSONSerialization.data(withJSONObject: fileSizes)
        try sizesData.write(to: sizesURL)

        debugLog(
            "[FilesystemActor] EPUB extracted (skipped \(skippedAudioFiles) audio, \(skippedErrors) errors, wrote \(fileSizes.count) files)"
        )

        return URL(fileURLWithPath: extractedDir.path, isDirectory: true)
    }

    private func derivedEpubExtractionDirectory(
        epubPath: URL,
        sourceID: BookSourceID,
        bookID: String,
        category: LocalMediaCategory,
    ) -> URL {
        let fingerprint = fileFingerprint(for: epubPath)
        return epubExtractionRootDirectory()
            .appendingPathComponent(sanitizedPathComponent(from: sourceID), isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(from: bookID), isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
            .appendingPathComponent("extracted", isDirectory: true)
    }

    private func fileFingerprint(for url: URL) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = attributes[.size] as? UInt64 ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let modifiedMilliseconds = Int64((modifiedAt * 1000).rounded())
        return "\(size)-\(modifiedMilliseconds)"
    }

    public func extractAudioData(from epubPath: URL, audioPath: String) async throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(url: epubPath, accessMode: .read)
        } catch {
            throw NSError(
                domain: "FilesystemActor",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to open EPUB archive for audio: \(epubPath.path) - \(error)"
                ],
            )
        }

        let pathsToTry = [audioPath] + ["OPS", "OEBPS", "epub"].map { "\($0)/\(audioPath)" }

        for path in pathsToTry {
            if let entry = archive[path] {
                var data = Data()
                _ = try archive.extract(entry, skipCRC32: true) { chunk in
                    data.append(chunk)
                }
                debugLog(
                    "[FilesystemActor] Extracted audio from EPUB: \(path) (\(data.count) bytes)"
                )
                return data
            }
        }

        throw NSError(
            domain: "FilesystemActor",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Audio file not found in EPUB: \(audioPath)"],
        )
    }

    public func extractAudioToFile(from epubPath: URL, audioPath: String, destination: URL)
        async throws
    {
        let archive: Archive
        do {
            archive = try Archive(url: epubPath, accessMode: .read)
        } catch {
            throw NSError(
                domain: "FilesystemActor",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to open EPUB archive for audio: \(epubPath.path) - \(error)"
                ],
            )
        }

        let pathsToTry = [audioPath] + ["OPS", "OEBPS", "epub"].map { "\($0)/\(audioPath)" }

        for path in pathsToTry {
            if let entry = archive[path] {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }

                _ = try archive.extract(entry, skipCRC32: true) { chunk in
                    handle.write(chunk)
                }
                debugLog(
                    "[FilesystemActor] Extracted audio to file: \(destination.path)"
                )
                return
            }
        }

        throw NSError(
            domain: "FilesystemActor",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Audio file not found in EPUB: \(audioPath)"],
        )
    }

    // MARK: - Smart Shelves Persistence

    public func saveSmartShelves(_ shelves: [SmartShelf]) throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let url = configDir.appendingPathComponent("smart_shelves.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(shelves)
        try data.write(to: url, options: .atomic)
    }

    public func loadSmartShelves() throws -> [SmartShelf] {
        let configDir = getConfigDirectory()
        let newUrl = configDir.appendingPathComponent("smart_shelves.json", isDirectory: false)
        let legacyUrl = configDir.appendingPathComponent(
            "dynamic_shelves.json",
            isDirectory: false,
        )

        let url: URL
        if FileManager.default.fileExists(atPath: newUrl.path) {
            url = newUrl
        } else if FileManager.default.fileExists(atPath: legacyUrl.path) {
            url = legacyUrl
        } else {
            return []
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SmartShelf].self, from: data)
    }

    // MARK: - Download State Persistence

    private func getResumeDataDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("ResumeData", isDirectory: true)
    }

    public func saveDownloadState(_ records: [DownloadRecord]) throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let url = configDir.appendingPathComponent("downloads.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
    }

    public func loadDownloadState() throws -> [DownloadRecord] {
        let configDir = getConfigDirectory()
        let url = configDir.appendingPathComponent("downloads.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DownloadRecord].self, from: data)
    }

    public func saveResumeData(_ resumeData: Data, for downloadId: String) throws {
        let dir = getResumeDataDirectory()
        try ensureDirectoryExists(at: dir)

        let url = dir.appendingPathComponent("\(downloadId).resumedata", isDirectory: false)
        try resumeData.write(to: url, options: .atomic)
    }

    public func loadResumeData(for downloadId: String) throws -> Data? {
        let dir = getResumeDataDirectory()
        let url = dir.appendingPathComponent("\(downloadId).resumedata", isDirectory: false)

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func hasResumeData(for downloadId: String) -> Bool {
        let dir = getResumeDataDirectory()
        let url = dir.appendingPathComponent("\(downloadId).resumedata", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func deleteResumeData(for downloadId: String) throws {
        let dir = getResumeDataDirectory()
        let url = dir.appendingPathComponent("\(downloadId).resumedata", isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    public func applicationSupportRelativePath(for url: URL) -> String? {
        let basePath = applicationSupportBaseDirectory().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == basePath || path.hasPrefix(basePath + "/") else {
            return nil
        }
        return String(path.dropFirst(basePath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    public func applicationSupportURL(relativePath: String) -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    public func resolvePersistedApplicationSupportURL(
        relativePath: String?,
        legacyAbsoluteURL: URL?,
    ) -> URL? {
        if let relativePath, !relativePath.isEmpty {
            return applicationSupportURL(relativePath: relativePath)
        }

        guard let legacyAbsoluteURL else { return nil }
        if let relativePath = applicationSupportRelativePath(for: legacyAbsoluteURL) {
            return applicationSupportURL(relativePath: relativePath)
        }

        let marker = "/Library/Application Support/"
        let path = legacyAbsoluteURL.standardizedFileURL.path
        guard let range = path.range(of: marker) else {
            return legacyAbsoluteURL
        }

        let relativePath = String(path[range.upperBound...])
        guard !relativePath.isEmpty else {
            return applicationSupportBaseDirectory()
        }
        return applicationSupportURL(relativePath: relativePath)
    }

    /// Rebases a persisted folder-source path that belongs to this app's Application
    /// Support container onto the *current* container. iOS changes the app's data UUID
    /// between builds, so an absolute path stored earlier can reference a container that
    /// no longer exists. A path that is not part of our own container layout — including a
    /// user-chosen external folder that merely happens to sit under some
    /// `Library/Application Support` directory — is returned unchanged.
    public func rebasedContainerFolderURL(for url: URL) -> URL {
        let base = applicationSupportBaseDirectory().standardizedFileURL.path
        let path = url.standardizedFileURL.path

        if path == base || path.hasPrefix(base + "/") {
            return url
        }

        let marker = "/Library/Application Support"
        guard
            let baseMarker = base.range(of: marker, options: .backwards),
            let pathMarker = path.range(of: marker, options: .backwards)
        else {
            return url
        }

        let separators = CharacterSet(charactersIn: "/")
        let baseTail = String(base[baseMarker.upperBound...]).trimmingCharacters(in: separators)
        let pathTail = String(path[pathMarker.upperBound...]).trimmingCharacters(in: separators)

        let relativeTail: String
        if baseTail.isEmpty {
            relativeTail = pathTail
        } else if pathTail == baseTail {
            relativeTail = ""
        } else if pathTail.hasPrefix(baseTail + "/") {
            relativeTail = String(pathTail.dropFirst(baseTail.count + 1))
        } else {
            return url
        }

        guard !relativeTail.isEmpty else {
            return applicationSupportBaseDirectory()
        }
        return applicationSupportBaseDirectory()
            .appendingPathComponent(relativeTail, isDirectory: true)
    }

    private nonisolated func applicationSupportBaseDirectory() -> URL {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "SilveranReader"

        #if os(tvOS)
        let cachesDir = try! fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        return cachesDir.appendingPathComponent(bundleID, isDirectory: true)
        #else
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )

        if appSupport.path.contains("/Containers/") {
            return appSupport
        } else {
            return appSupport.appendingPathComponent(bundleID, isDirectory: true)
        }
        #endif
    }
}
