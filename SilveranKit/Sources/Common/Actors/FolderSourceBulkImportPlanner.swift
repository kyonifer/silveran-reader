import Foundation

public struct FolderSourceBulkImportPlanner: Sendable {
    private let localLibrary: LocalLibraryManager

    private static let audioExtensions: Set<String> = [
        "aac", "flac", "m4a", "m4b", "mp3", "ogg", "opus", "wav",
    ]
    private static let groupingFolderNames: Set<String> = [
        "audio", "audiobook", "audiobooks", "ebook", "ebooks", "readaloud", "synced",
    ]

    public init(localLibrary: LocalLibraryManager = LocalLibraryManager()) {
        self.localLibrary = localLibrary
    }

    public func planImport(from rootURL: URL) async -> FolderSourceBulkImportPlan {
        let root = rootURL.standardizedFileURL
        var candidates: [Candidate] = []
        var skippedFiles: [FolderSourceBulkImportSkippedFile] = []

        guard let fileURLs = regularFiles(in: root) else {
            return FolderSourceBulkImportPlan(
                rootURL: root,
                groups: [],
                skippedFiles: [
                    FolderSourceBulkImportSkippedFile(
                        relativePath: root.lastPathComponent,
                        reason: "Folder could not be read",
                    )
                ],
            )
        }

        for fileURL in fileURLs {
            let relativePath = self.relativePath(for: fileURL, root: root)
            let ext = fileURL.pathExtension.lowercased()
            if ext == "epub" {
                let candidate = await epubCandidate(
                    fileURL,
                    root: root,
                    relativePath: relativePath,
                )
                candidates.append(candidate)
            } else if Self.audioExtensions.contains(ext) {
                let candidate = await audioCandidate(
                    fileURL,
                    root: root,
                    relativePath: relativePath,
                )
                candidates.append(candidate)
            } else if fileURL.lastPathComponent == "manifest.json" {
                skippedFiles.append(
                    FolderSourceBulkImportSkippedFile(
                        relativePath: relativePath,
                        reason: "Audiobook manifests are regenerated during import",
                    )
                )
            }
        }

        let groups = makeGroups(from: candidates, root: root)
        return FolderSourceBulkImportPlan(
            rootURL: root,
            groups: groups,
            skippedFiles: skippedFiles,
        )
    }

    private func regularFiles(in root: URL) -> [URL]? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
            )
        else {
            return nil
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            guard isRegularFile(fileURL) else { continue }
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private struct Candidate: Sendable, Hashable {
        let asset: FolderSourceBulkImportAsset
        let groupingDirectory: URL
        let normalizedStem: String
    }

    private func epubCandidate(_ fileURL: URL, root: URL, relativePath: String) async -> Candidate {
        let isReadaloud = localLibrary.isReadaloudEpub(at: fileURL)
        let role: FolderSourceBulkImportRole = isReadaloud ? .readaloud : .ebook
        var title: String?
        var warnings: [String] = []

        do {
            title = try await localLibrary.extractMetadata(
                from: fileURL,
                category: role.localMediaCategory ?? .ebook,
            )
            .title
        } catch {
            warnings.append("Could not read EPUB metadata")
        }

        let asset = FolderSourceBulkImportAsset(
            url: fileURL,
            relativePath: relativePath,
            filename: fileURL.lastPathComponent,
            fileSize: fileSize(fileURL),
            detectedTitle: title,
            detectedRole: role,
            selectedRole: role,
            warnings: warnings,
        )
        return Candidate(
            asset: asset,
            groupingDirectory: groupingDirectory(for: fileURL, root: root),
            normalizedStem: normalizedStem(for: fileURL),
        )
    }

    private func audioCandidate(_ fileURL: URL, root: URL, relativePath: String) async -> Candidate
    {
        var title: String?
        var warnings: [String] = []

        do {
            title = try await localLibrary.extractMetadata(from: fileURL, category: .audio).title
        } catch {
            warnings.append("Could not read audio metadata")
        }

        let asset = FolderSourceBulkImportAsset(
            url: fileURL,
            relativePath: relativePath,
            filename: fileURL.lastPathComponent,
            fileSize: fileSize(fileURL),
            detectedTitle: title,
            detectedRole: .audiobook,
            selectedRole: .audiobook,
            warnings: warnings,
        )
        return Candidate(
            asset: asset,
            groupingDirectory: groupingDirectory(for: fileURL, root: root),
            normalizedStem: normalizedStem(for: fileURL),
        )
    }

    private func makeGroups(from candidates: [Candidate], root: URL)
        -> [FolderSourceBulkImportGroup]
    {
        let byDirectory = Dictionary(grouping: candidates) {
            $0.groupingDirectory.standardizedFileURL.path
        }
        var groups: [FolderSourceBulkImportGroup] = []

        for directoryPath in byDirectory.keys.sorted(by: localizedPathCompare) {
            guard let directoryCandidates = byDirectory[directoryPath] else { continue }
            groups.append(contentsOf: groupsForDirectory(directoryCandidates, root: root))
        }

        return groups.sorted {
            $0.title.articleStrippedCompare($1.title) == .orderedAscending
        }
    }

    private func groupsForDirectory(
        _ candidates: [Candidate],
        root _: URL,
    ) -> [FolderSourceBulkImportGroup] {
        let sorted = candidates.sorted {
            $0.asset.relativePath.localizedStandardCompare($1.asset.relativePath)
                == .orderedAscending
        }
        let epubCount = sorted.filter {
            $0.asset.detectedRole == .ebook || $0.asset.detectedRole == .readaloud
        }
        .count
        let audioCount = sorted.filter { $0.asset.detectedRole == .audiobook }.count

        if audioCount == 1 && epubCount <= 2 {
            return [singleGroup(from: sorted)]
        }

        if epubCount <= 2 && sorted.count <= 4 && hasMeaningfulCommonStem(sorted) {
            return [singleGroup(from: sorted)]
        }

        if audioCount > 1 && epubCount == 0 && hasMeaningfulCommonStem(sorted) {
            return [singleGroup(from: sorted)]
        }

        var result: [FolderSourceBulkImportGroup] = []
        let audioCandidates = sorted.filter { $0.asset.detectedRole == .audiobook }
        if audioCandidates.count > 1 {
            result.append(contentsOf: audioCandidates.map { singleGroup(from: [$0]) })
        } else if !audioCandidates.isEmpty {
            result.append(singleGroup(from: audioCandidates))
        }
        for candidate in sorted where candidate.asset.detectedRole != .audiobook {
            result.append(singleGroup(from: [candidate]))
        }
        return result
    }

    private func singleGroup(from candidates: [Candidate]) -> FolderSourceBulkImportGroup {
        var assets = candidates.map(\.asset)
        var warnings: [String] = []
        normalizeEpubRoles(&assets, warnings: &warnings)

        let title = groupTitle(for: assets, fallbackDirectory: candidates.first?.groupingDirectory)
        if assets.filter({ $0.selectedRole == .ebook }).count > 1 {
            warnings.append("Multiple ebook files are assigned")
        }
        if assets.filter({ $0.selectedRole == .readaloud }).count > 1 {
            warnings.append("Multiple readaloud files are assigned")
        }

        return FolderSourceBulkImportGroup(
            title: title,
            assets: assets,
            warnings: warnings,
        )
    }

    private func normalizeEpubRoles(
        _ assets: inout [FolderSourceBulkImportAsset],
        warnings: inout [String],
    ) {
        var ebookIndexes = assets.indices.filter { assets[$0].selectedRole == .ebook }
        let readaloudIndexes = assets.indices.filter { assets[$0].selectedRole == .readaloud }
        guard readaloudIndexes.isEmpty, ebookIndexes.count > 1 else { return }

        ebookIndexes.sort {
            (assets[$0].fileSize ?? 0) > (assets[$1].fileSize ?? 0)
        }
        if let largest = ebookIndexes.first {
            assets[largest].selectedRole = .readaloud
            warnings.append("Multiple EPUBs found; largest EPUB is tentatively marked readaloud")
        }
    }

    private func groupTitle(
        for assets: [FolderSourceBulkImportAsset],
        fallbackDirectory: URL?,
    ) -> String {
        if let title = assets.first(where: { $0.selectedRole == .ebook })?.detectedTitle,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title
        }
        if let title = assets.first(where: { $0.selectedRole == .readaloud })?.detectedTitle,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title
        }
        if let title = assets.first?.detectedTitle,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title
        }
        if let fallbackDirectory, !fallbackDirectory.lastPathComponent.isEmpty {
            return fallbackDirectory.lastPathComponent
        }
        return assets.first?.url.deletingPathExtension().lastPathComponent ?? "Untitled Book"
    }

    private func hasMeaningfulCommonStem(_ candidates: [Candidate]) -> Bool {
        guard let first = candidates.first?.normalizedStem, first.count >= 4 else { return false }
        return candidates.dropFirst().allSatisfy { candidate in
            first.hasPrefix(candidate.normalizedStem) || candidate.normalizedStem.hasPrefix(first)
        }
    }

    private func groupingDirectory(for fileURL: URL, root: URL) -> URL {
        let parent = fileURL.deletingLastPathComponent()
        let parentName = parent.lastPathComponent.lowercased()
        if Self.groupingFolderNames.contains(parentName) {
            let grandparent = parent.deletingLastPathComponent()
            return grandparent.path.isEmpty ? root : grandparent
        }
        return parent
    }

    private func normalizedStem(for fileURL: URL) -> String {
        let stem = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        let roleWords = [
            "readaloud", "read aloud", "media overlay", "media overlays", "audiobook",
            "audio book", "ebook", "epub", "unabridged",
        ]
        var normalized = stem
        for word in roleWords {
            normalized = normalized.replacingOccurrences(of: word, with: " ")
        }
        normalized = normalized.replacingOccurrences(
            of: #"[\W_]+"#,
            with: " ",
            options: .regularExpression,
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        return String(filePath[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func fileSize(_ fileURL: URL) -> Int64? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }

    private func isRegularFile(_ fileURL: URL) -> Bool {
        (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func localizedPathCompare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
