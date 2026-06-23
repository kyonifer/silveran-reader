import Foundation

extension FilesystemActor {
    private static let legacyLocalProgressMigrationID = "folder-source-legacy-progress-v1"

    func runLegacyLocalProgressMigrationIfNeeded(sources: [BookSourceRecord]) async {
        guard !migrationSentinelExists(Self.legacyLocalProgressMigrationID) else { return }

        guard let legacy = loadStashedLegacyLocalLibraryMetadata(), !legacy.isEmpty,
            let source = sources.first(where: {
                $0.kind == .localFolder && $0.storageBookmarkData == nil
            })
        else {
            finishLegacyLocalProgressMigration()
            return
        }

        // Leave the sentinel and stash intact on any failure below so a transient
        // unreadable folder or write error retries on the next launch.
        let folderURL = internalFolderSourceDirectory()
        do {
            _ = try await FolderSourceActor(sourceRecord: source).scanLibrary(in: folderURL)
            guard let scanned = try loadFolderSourceLibraryState(in: folderURL) else {
                debugLog("[SilveranMigrations] Legacy local progress migration found no scanned state")
                return
            }
            let merged = LegacyLocalProgressMerge.merge(into: scanned, legacy: legacy)
            try saveFolderSourceLibraryState(merged, in: folderURL)
        } catch {
            debugLog("[SilveranMigrations] Legacy local progress migration failed: \(error)")
            return
        }

        finishLegacyLocalProgressMigration()
    }

    private func finishLegacyLocalProgressMigration() {
        try? writeMigrationSentinel(Self.legacyLocalProgressMigrationID)
        removeStashedLegacyLocalLibraryMetadata()
    }
}

enum LegacyLocalProgressMerge {
    static func merge(
        into state: FolderSourceLibraryState,
        legacy: [BookMetadata],
    ) -> FolderSourceLibraryState {
        let candidates = legacy.filter {
            $0.position != nil || $0.status != nil || $0.rating != nil
        }
        guard !candidates.isEmpty else { return state }

        var state = state
        let mediaByID = Dictionary(uniqueKeysWithValues: state.media.map { ($0.uuid, $0) })
        let index = state.works.enumerated().map { offset, work in
            (
                offset: offset, names: filenames(of: work, mediaByID: mediaByID),
                title: titleKey(work.title),
            )
        }

        var consumed: Set<Int> = []
        for book in candidates {
            let bookNames = filenames(of: book)
            let bookTitle = titleKey(book.title)
            let match =
                index.first {
                    !consumed.contains($0.offset) && !bookNames.isEmpty
                        && !$0.names.isDisjoint(with: bookNames)
                }?.offset
                ?? index.first {
                    !consumed.contains($0.offset) && !bookTitle.isEmpty && $0.title == bookTitle
                }?.offset
            guard let offset = match else { continue }
            consumed.insert(offset)
            if !book.uuid.isEmpty { state.works[offset].uuid = book.uuid }
            if state.works[offset].position == nil { state.works[offset].position = book.position }
            if state.works[offset].status == nil { state.works[offset].status = book.status }
            if state.works[offset].rating == nil { state.works[offset].rating = book.rating }
        }
        return state
    }

    private static func filenames(
        of work: FolderSourceWork,
        mediaByID: [String: FolderSourceMedia],
    ) -> Set<String> {
        Set(
            work.mediaIDs.values
                .compactMap { mediaByID[$0] }
                .flatMap(\.relativePaths)
                .map { ($0 as NSString).lastPathComponent.lowercased() }
        )
    }

    private static func filenames(of book: BookMetadata) -> Set<String> {
        Set(
            [book.ebook?.filepath, book.audiobook?.filepath, book.readaloud?.filepath ?? nil]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .map { ($0 as NSString).lastPathComponent.lowercased() }
        )
    }

    private static func titleKey(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
