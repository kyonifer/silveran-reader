import Foundation

extension FilesystemActor {
    func createDefaultBookSources() throws -> [BookSourceRecord] {
        let now = SilveranDate.isoTimestamp(from: Date())
        let sources = [
            try createDefaultBookSource(
                kind: .storyteller,
                name: BookSourceKind.storyteller.defaultName,
                timestamp: now,
            ),
            try createDefaultBookSource(
                kind: .localFolder,
                name: BookSourceKind.localFolder.defaultName,
                timestamp: now,
            ),
        ]

        try saveBookSources(sources)
        return sources
    }

    private func createDefaultBookSource(
        kind: BookSourceKind,
        name: String,
        timestamp: String,
    ) throws -> BookSourceRecord {
        let sourceID = UUID().uuidString
        let directory =
            kind == .localFolder
            ? try ensureInternalFolderSourceDirectory(sourceID: sourceID)
            : nil
        return BookSourceRecord(
            id: sourceID,
            name: name,
            kind: kind,
            capabilities: kind == .storyteller ? .storyteller : .localFolder,
            createdAt: timestamp,
            updatedAt: timestamp,
            storagePath: directory?.path,
        )
    }
}
