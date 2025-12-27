import Foundation
import ZIPFoundation

/// Handles filesystem storage for local media, including directory management and metadata persistence.
public actor FilesystemActor {
    public static let shared = FilesystemActor()

    public init() {}

    public func ensureLocalStorageDirectories() throws {
        for domain in LocalMediaDomain.allCases {
            let domainDir = getDomainDirectory(for: domain)
            try ensureDirectoryExists(at: domainDir)
        }
    }

    public func getDomainDirectory(for domain: LocalMediaDomain) -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent(domain.rawValue, isDirectory: true)
    }

    public func getMediaDirectory(
        domain: LocalMediaDomain,
        category: LocalMediaCategory,
        bookName: String,
        uuidIdentifier: String? = nil
    ) async -> URL {
        let folderName = await resolveBookFolderName(
            for: domain,
            bookName: bookName,
            uuidIdentifier: uuidIdentifier
        )
        return getDomainDirectory(for: domain)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
    }

    public func resolveBookFolderName(
        for domain: LocalMediaDomain,
        bookName: String,
        uuidIdentifier: String?
    ) async -> String {
        let domainDir = getDomainDirectory(for: domain)
        let sanitizedBase = sanitizedPathComponent(from: bookName)
        let uuidSanitized: String? = {
            guard let uuidIdentifier else { return nil }
            let sanitized = sanitizedPathComponent(from: uuidIdentifier)
            return sanitized.isEmpty ? nil : sanitized
        }()

        if let uuidSanitized {
            if let existing = try? await existingFolder(
                matching: uuidSanitized,
                in: domainDir
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

    public func downloadedCategories(
        for uuid: String,
        in domain: LocalMediaDomain
    ) async -> Set<LocalMediaCategory> {
        let domainDir = getDomainDirectory(for: domain)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: domainDir
            )
        else {
            return []
        }

        let fm = FileManager.default
        let bookRoot = domainDir.appendingPathComponent(folderName, isDirectory: true)
        var results: Set<LocalMediaCategory> = []

        for category in LocalMediaCategory.allCases {
            let categoryDir = bookRoot.appendingPathComponent(category.rawValue, isDirectory: true)
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: categoryDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            if contents.contains(where: { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                    return false
                }
                return values.isDirectory != true
            }) {
                results.insert(category)
            }
        }

        return results
    }

    public func mediaDirectory(
        for uuid: String,
        category: LocalMediaCategory,
        in domain: LocalMediaDomain
    ) async -> URL? {
        let domainDir = getDomainDirectory(for: domain)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: domainDir
            )
        else {
            return nil
        }

        let categoryDir =
            domainDir
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: categoryDir.path) else { return nil }
        return categoryDir
    }

    public func deleteMedia(
        for uuid: String,
        category: LocalMediaCategory,
        in domain: LocalMediaDomain
    ) async throws {
        let domainDir = getDomainDirectory(for: domain)
        let sanitizedUuid = sanitizedPathComponent(from: uuid)
        guard
            let folderName = try? await existingFolder(
                matching: sanitizedUuid,
                in: domainDir
            )
        else {
            return
        }

        let categoryDir =
            domainDir
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

    public func saveStorytellerLibraryMetadata(_ metadata: [BookMetadata]) throws {
        let domainDir = getDomainDirectory(for: .storyteller)
        try ensureDirectoryExists(at: domainDir)

        let metadataURL = domainDir.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try write(data: data, to: metadataURL)
    }

    public func loadStorytellerLibraryMetadata() throws -> [BookMetadata]? {
        let domainDir = getDomainDirectory(for: .storyteller)
        let metadataURL = domainDir.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false
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

    public func saveLocalLibraryMetadata(_ metadata: [BookMetadata]) throws {
        let domainDir = getDomainDirectory(for: .local)
        try ensureDirectoryExists(at: domainDir)

        let metadataURL = domainDir.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try write(data: data, to: metadataURL)
    }

    public func loadLocalLibraryMetadata() throws -> [BookMetadata]? {
        let domainDir = getDomainDirectory(for: .local)
        let metadataURL = domainDir.appendingPathComponent(
            "library_metadata.json",
            isDirectory: false
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

    public func getConfigDirectory() -> URL {
        applicationSupportBaseDirectory()
            .appendingPathComponent("Config", isDirectory: true)
    }

    public func loadProgressQueue() throws -> [PendingProgressSync] {
        let configDir = getConfigDirectory()
        let queueURL = configDir.appendingPathComponent(
            "offline_progress_queue.json",
            isDirectory: false
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

    public func saveProgressQueue(_ queue: [PendingProgressSync]) throws {
        let configDir = getConfigDirectory()
        try ensureDirectoryExists(at: configDir)

        let queueURL = configDir.appendingPathComponent(
            "offline_progress_queue.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(queue)

        let tempURL = configDir.appendingPathComponent(
            "offline_progress_queue.tmp",
            isDirectory: false
        )
        try data.write(to: tempURL, options: .atomic)

        let fm = FileManager.default
        if fm.fileExists(atPath: queueURL.path) {
            try fm.removeItem(at: queueURL)
        }
        try fm.moveItem(at: tempURL, to: queueURL)
    }

    public func saveCoverImage(uuid: String, data: Data, variant: String) throws {
        let coversDir = applicationSupportBaseDirectory()
            .appendingPathComponent("Covers", isDirectory: true)
        try ensureDirectoryExists(at: coversDir)

        let filename = "\(uuid)_\(variant).dat"
        let coverURL = coversDir.appendingPathComponent(filename, isDirectory: false)
        try write(data: data, to: coverURL)
    }

    public func loadCoverImage(uuid: String, variant: String) -> Data? {
        let coversDir = applicationSupportBaseDirectory()
            .appendingPathComponent("Covers", isDirectory: true)
        let filename = "\(uuid)_\(variant).dat"
        let coverURL = coversDir.appendingPathComponent(filename, isDirectory: false)

        let fm = FileManager.default
        guard fm.fileExists(atPath: coverURL.path) else {
            return nil
        }

        return try? Data(contentsOf: coverURL)
    }

    public func removeAllStorytellerData() throws {
        let storytellerDir = getDomainDirectory(for: .storyteller)
        let fm = FileManager.default

        if fm.fileExists(atPath: storytellerDir.path) {
            try fm.removeItem(at: storytellerDir)
        }

        let coversDir = applicationSupportBaseDirectory()
            .appendingPathComponent("Covers", isDirectory: true)
        if fm.fileExists(atPath: coversDir.path) {
            try fm.removeItem(at: coversDir)
        }
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
            isDirectory: false
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
            isDirectory: false
        )

        let bookHighlights = BookHighlights(bookId: bookId, highlights: highlights)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bookHighlights)

        let tempURL = highlightsDir.appendingPathComponent(
            "\(sanitizedBookId).tmp",
            isDirectory: false
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
            isDirectory: false
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    private func existingFolder(
        matching uuidSanitized: String,
        in domainDirectory: URL
    ) async throws -> String? {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: domainDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
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
                subdirectory: "WebResources"
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find foliate_wrap.html in bundle"]
            )
        }

        guard
            let foliateJSURL = Bundle.main.url(
                forResource: "foliate-js",
                withExtension: nil
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find foliate-js folder in bundle"]
            )
        }

        let htmlDestination = webResourcesDir.appendingPathComponent("foliate_wrap.html")
        if fm.fileExists(atPath: htmlDestination.path) {
            try fm.removeItem(at: htmlDestination)
        }
        try fm.copyItem(at: htmlURL, to: htmlDestination)

        let foliateJSDestination = webResourcesDir.appendingPathComponent(
            "foliate-js",
            isDirectory: true
        )
        if fm.fileExists(atPath: foliateJSDestination.path) {
            try fm.removeItem(at: foliateJSDestination)
        }
        try fm.copyItem(at: foliateJSURL, to: foliateJSDestination)

        guard
            let jsFileURLs = Bundle.main.urls(
                forResourcesWithExtension: "js",
                subdirectory: "WebResources"
            )
        else {
            throw NSError(
                domain: "FilesystemActor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to find any .js files in bundle"]
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

        for domain in LocalMediaDomain.allCases {
            let domainDir = getDomainDirectory(for: domain)
            guard
                let bookFolders = try? fm.contentsOfDirectory(
                    at: domainDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
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

    public func extractEpubIfNeeded(
        epubPath: URL,
        sizeThresholdMB: Int = 200,
        forceExtract: Bool = false
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

        let extractedDir = epubPath.deletingLastPathComponent()
            .appendingPathComponent("extracted", isDirectory: true)

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
                ]
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
                ]
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
            userInfo: [NSLocalizedDescriptionKey: "Audio file not found in EPUB: \(audioPath)"]
        )
    }

    private func applicationSupportBaseDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "SilveranReader"

        if appSupport.path.contains("/Containers/") {
            return appSupport
        } else {
            return appSupport.appendingPathComponent(bundleID, isDirectory: true)
        }
    }
}
