import Foundation
import ZIPFoundation

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class LocalLibraryManager: Sendable {

    public init() {}

    public func extractMetadata(from fileURL: URL, category: LocalMediaCategory) async throws
        -> BookMetadata
    {
        switch category {
            case .ebook, .synced:
                return try await extractEpubMetadata(from: fileURL)
            case .audio:
                return try await extractAudioMetadata(from: fileURL)
        }
    }

    public struct ScanResult: Sendable {
        public let metadata: [BookMetadata]
        public let paths: [String: MediaPaths]
    }

    public func scanLocalMedia(filesystem: FilesystemActor) async throws -> ScanResult {
        let localDir = await filesystem.getDomainDirectory(for: .local)
        let fm = FileManager.default

        guard
            let bookFolders = try? fm.contentsOfDirectory(
                at: localDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return ScanResult(metadata: [], paths: [:])
        }

        var allMetadata: [BookMetadata] = []
        var allPaths: [String: MediaPaths] = [:]
        var seenFiles: Set<String> = []

        for bookFolder in bookFolders {
            guard let values = try? bookFolder.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true
            else {
                continue
            }

            for category in LocalMediaCategory.allCases {
                let categoryDir = bookFolder.appendingPathComponent(
                    category.rawValue,
                    isDirectory: true
                )
                guard
                    let files = try? fm.contentsOfDirectory(
                        at: categoryDir,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    )
                else {
                    continue
                }

                for fileURL in files {
                    let ext = fileURL.pathExtension.lowercased()
                    guard ext == "epub" || ext == "m4b" else { continue }

                    let fullPath = fileURL.path
                    if seenFiles.contains(fullPath) {
                        continue
                    }
                    seenFiles.insert(fullPath)

                    do {
                        let metadata = try await extractMetadata(from: fileURL, category: category)
                        allMetadata.append(metadata)

                        var mediaPaths = allPaths[metadata.uuid] ?? MediaPaths()

                        if metadata.hasAvailableReadaloud {
                            mediaPaths.syncedPath = fileURL
                        } else if metadata.hasAvailableAudiobook {
                            mediaPaths.audioPath = fileURL
                        } else {
                            mediaPaths.ebookPath = fileURL
                        }
                        allPaths[metadata.uuid] = mediaPaths

                        debugLog(
                            "[LocalLibraryManager] Discovered local file: \(fileURL.lastPathComponent) (readaloud: \(metadata.hasAvailableReadaloud))"
                        )
                    } catch {
                        debugLog(
                            "[LocalLibraryManager] Failed to extract metadata from \(fileURL.lastPathComponent): \(error)"
                        )
                    }
                }
            }
        }

        return ScanResult(metadata: allMetadata, paths: allPaths)
    }

    public func isReadaloudEpub(at epubURL: URL) -> Bool {
        let archive: Archive
        do {
            archive = try Archive(url: epubURL, accessMode: .read)
        } catch {
            return false
        }

        for entry in archive {
            if entry.path.lowercased().hasSuffix(".smil") {
                return true
            }
        }
        return false
    }

    private func extractEpubMetadata(from epubURL: URL) async throws -> BookMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: epubURL, accessMode: .read)
        } catch {
            throw LocalLibraryError.failedToOpenArchive(epubURL.path)
        }

        let opfPath = try findOPFPath(in: archive)
        let opfData = try extractFile(archive: archive, path: opfPath)

        guard let opfString = String(data: opfData, encoding: .utf8) else {
            throw LocalLibraryError.invalidOPFEncoding
        }

        let parsed = parseOPF(opfString)
        let isReadaloud = isReadaloudEpub(at: epubURL)

        let bookUUID = UUID().uuidString
        let title = parsed.title ?? epubURL.deletingPathExtension().lastPathComponent

        let authors: [BookCreator]? =
            parsed.creators.isEmpty
            ? nil
            : parsed.creators.map { name in
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: name,
                    fileAs: nil,
                    role: "author",
                    createdAt: nil,
                    updatedAt: nil
                )
            }

        let ebookAsset: BookAsset?
        let readaloudAsset: BookReadaloud?

        if isReadaloud {
            ebookAsset = nil
            readaloudAsset = BookReadaloud(
                uuid: bookUUID,
                filepath: epubURL.lastPathComponent,
                missing: 0,
                status: "aligned",
                currentStage: nil,
                stageProgress: nil,
                queuePosition: nil,
                restartPending: nil,
                createdAt: nil,
                updatedAt: nil
            )
        } else {
            ebookAsset = BookAsset(
                uuid: bookUUID,
                filepath: epubURL.lastPathComponent,
                missing: 0,
                createdAt: nil,
                updatedAt: nil
            )
            readaloudAsset = nil
        }

        return BookMetadata(
            uuid: bookUUID,
            title: title,
            subtitle: nil,
            description: parsed.description,
            language: parsed.language,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: parsed.date,
            authors: authors,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: ebookAsset,
            audiobook: nil,
            readaloud: readaloudAsset,
            status: nil,
            position: nil,
            rating: nil
        )
    }

    private func extractAudioMetadata(from audioURL: URL) async throws -> BookMetadata {
        let bookUUID = UUID().uuidString
        var title = audioURL.deletingPathExtension().lastPathComponent
        var authorName: String?

        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: audioURL)
        let metadata = try await asset.load(.commonMetadata)

        for item in metadata {
            guard let key = item.commonKey else { continue }

            switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue) {
                        title = value
                    }
                case .commonKeyArtist, .commonKeyAuthor:
                    if let value = try? await item.load(.stringValue) {
                        authorName = value
                    }
                default:
                    break
            }
        }
        #endif

        let authors: [BookCreator]? = authorName.map { name in
            [
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: name,
                    fileAs: nil,
                    role: "author",
                    createdAt: nil,
                    updatedAt: nil
                )
            ]
        }

        let audiobookAsset = BookAsset(
            uuid: bookUUID,
            filepath: audioURL.lastPathComponent,
            missing: 0,
            createdAt: nil,
            updatedAt: nil
        )

        return BookMetadata(
            uuid: bookUUID,
            title: title,
            subtitle: nil,
            description: nil,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: authors,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: nil,
            audiobook: audiobookAsset,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil
        )
    }

    private func findOPFPath(in archive: Archive) throws -> String {
        let containerPath = "META-INF/container.xml"
        let containerData = try extractFile(archive: archive, path: containerPath)

        guard let containerString = String(data: containerData, encoding: .utf8) else {
            throw LocalLibraryError.invalidContainerXML
        }

        guard
            let rootfileMatch = containerString.range(
                of: "full-path=\"[^\"]+\"",
                options: .regularExpression
            ),
            let pathStart = containerString.range(of: "\"", range: rootfileMatch),
            let pathEnd = containerString.range(
                of: "\"",
                range: pathStart.upperBound..<rootfileMatch.upperBound
            )
        else {
            throw LocalLibraryError.opfPathNotFound
        }

        return String(containerString[pathStart.upperBound..<pathEnd.lowerBound])
    }

    private func extractFile(archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw LocalLibraryError.fileNotFoundInArchive(path)
        }

        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
        }
        return data
    }

    private struct ParsedOPF {
        var title: String?
        var creators: [String] = []
        var description: String?
        var language: String?
        var date: String?
    }

    private func parseOPF(_ opfString: String) -> ParsedOPF {
        var result = ParsedOPF()

        result.title = extractDCElement(from: opfString, element: "title")
        result.description = extractDCElement(from: opfString, element: "description")
        result.language = extractDCElement(from: opfString, element: "language")
        result.date = extractDCElement(from: opfString, element: "date")

        result.creators = extractAllDCElements(from: opfString, element: "creator")

        return result
    }

    private func extractDCElement(from xml: String, element: String) -> String? {
        let patterns = [
            "<dc:\(element)[^>]*>([^<]+)</dc:\(element)>",
            "<dc:\(element)[^>]*><!\\[CDATA\\[([^\\]]+)\\]\\]></dc:\(element)>",
        ]

        for pattern in patterns {
            if let range = xml.range(of: pattern, options: .regularExpression) {
                let match = String(xml[range])
                if let contentStart = match.firstIndex(of: ">"),
                    let contentEnd = match.lastIndex(of: "<")
                {
                    var content = String(match[match.index(after: contentStart)..<contentEnd])
                    content = content.replacingOccurrences(of: "<![CDATA[", with: "")
                    content = content.replacingOccurrences(of: "]]>", with: "")
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }
        return nil
    }

    private func extractAllDCElements(from xml: String, element: String) -> [String] {
        var results: [String] = []
        let pattern = "<dc:\(element)[^>]*>([^<]+)</dc:\(element)>"

        var searchRange = xml.startIndex..<xml.endIndex
        while let range = xml.range(of: pattern, options: .regularExpression, range: searchRange) {
            let match = String(xml[range])
            if let contentStart = match.firstIndex(of: ">"),
                let contentEnd = match.lastIndex(of: "<")
            {
                let content = String(match[match.index(after: contentStart)..<contentEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    results.append(content)
                }
            }
            searchRange = range.upperBound..<xml.endIndex
        }

        return results
    }

    public func extractCoverFromEpub(at epubURL: URL) -> Data? {
        let archive: Archive
        do {
            archive = try Archive(url: epubURL, accessMode: .read)
        } catch {
            return nil
        }

        guard let opfPath = try? findOPFPath(in: archive),
            let opfData = try? extractFile(archive: archive, path: opfPath),
            let opfString = String(data: opfData, encoding: .utf8)
        else {
            return nil
        }

        let opfDir = (opfPath as NSString).deletingLastPathComponent

        if let coverHref = findCoverHref(in: opfString) {
            let coverPath = opfDir.isEmpty ? coverHref : "\(opfDir)/\(coverHref)"
            if let data = try? extractFile(archive: archive, path: coverPath) {
                return data
            }
            if let data = try? extractFile(archive: archive, path: coverHref) {
                return data
            }
        }

        let commonCoverPaths = [
            "cover.jpg", "cover.jpeg", "cover.png",
            "images/cover.jpg", "images/cover.jpeg", "images/cover.png",
            "OEBPS/cover.jpg", "OEBPS/cover.jpeg", "OEBPS/cover.png",
            "OEBPS/images/cover.jpg", "OEBPS/images/cover.jpeg", "OEBPS/images/cover.png",
            "OPS/cover.jpg", "OPS/cover.jpeg", "OPS/cover.png",
            "OPS/images/cover.jpg", "OPS/images/cover.jpeg", "OPS/images/cover.png",
        ]

        for path in commonCoverPaths {
            if let data = try? extractFile(archive: archive, path: path) {
                return data
            }
        }

        return nil
    }

    private func findCoverHref(in opfString: String) -> String? {
        var coverId: String?
        let metaPattern = "<meta[^>]*name=[\"']cover[\"'][^>]*content=[\"']([^\"']+)[\"']"
        let metaPatternAlt = "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*name=[\"']cover[\"']"

        for pattern in [metaPattern, metaPatternAlt] {
            if let range = opfString.range(of: pattern, options: .regularExpression) {
                let match = String(opfString[range])
                if let contentStart = match.range(of: "content=\"")?.upperBound
                    ?? match.range(of: "content='")?.upperBound,
                    let contentEnd = match[contentStart...].firstIndex(where: {
                        $0 == "\"" || $0 == "'"
                    })
                {
                    coverId = String(match[contentStart..<contentEnd])
                    break
                }
            }
        }

        if let coverId = coverId {
            let itemPattern = "<item[^>]*id=[\"']\(coverId)[\"'][^>]*href=[\"']([^\"']+)[\"']"
            let itemPatternAlt = "<item[^>]*href=[\"']([^\"']+)[\"'][^>]*id=[\"']\(coverId)[\"']"

            for pattern in [itemPattern, itemPatternAlt] {
                if let range = opfString.range(of: pattern, options: .regularExpression) {
                    let match = String(opfString[range])
                    if let hrefStart = match.range(of: "href=\"")?.upperBound
                        ?? match.range(of: "href='")?.upperBound,
                        let hrefEnd = match[hrefStart...].firstIndex(where: {
                            $0 == "\"" || $0 == "'"
                        })
                    {
                        return String(match[hrefStart..<hrefEnd])
                    }
                }
            }
        }

        let coverItemPattern =
            "<item[^>]*properties=[\"'][^\"']*cover-image[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']"
        if let range = opfString.range(of: coverItemPattern, options: .regularExpression) {
            let match = String(opfString[range])
            if let hrefStart = match.range(of: "href=\"")?.upperBound
                ?? match.range(of: "href='")?.upperBound,
                let hrefEnd = match[hrefStart...].firstIndex(where: { $0 == "\"" || $0 == "'" })
            {
                return String(match[hrefStart..<hrefEnd])
            }
        }

        return nil
    }

    public func extractCoverFromAudiobook(at audioURL: URL) async -> Data? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: audioURL)
        guard let metadata = try? await asset.load(.commonMetadata) else {
            return nil
        }

        for item in metadata {
            guard item.commonKey == .commonKeyArtwork else { continue }
            if let data = try? await item.load(.dataValue) {
                return data
            }
        }
        #endif
        return nil
    }
}

public enum LocalLibraryError: Error, LocalizedError {
    case failedToOpenArchive(String)
    case invalidContainerXML
    case opfPathNotFound
    case fileNotFoundInArchive(String)
    case invalidOPFEncoding

    public var errorDescription: String? {
        switch self {
            case .failedToOpenArchive(let path):
                return "Failed to open archive: \(path)"
            case .invalidContainerXML:
                return "Invalid container.xml encoding"
            case .opfPathNotFound:
                return "OPF path not found in container.xml"
            case .fileNotFoundInArchive(let path):
                return "File not found in archive: \(path)"
            case .invalidOPFEncoding:
                return "Invalid OPF file encoding"
        }
    }
}
