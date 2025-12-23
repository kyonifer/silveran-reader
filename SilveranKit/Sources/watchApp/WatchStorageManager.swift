import Foundation

public final class WatchStorageManager: Sendable {
    public static let shared = WatchStorageManager()

    private var fileManager: FileManager { FileManager.default }

    private var booksDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("books", isDirectory: true)
    }

    private var chunksDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("chunks", isDirectory: true)
    }

    private var libraryFile: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("library.json")
    }

    private init() {
        ensureDirectoriesExist()
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
    }

    public func getBookDirectory(uuid: String, category: String) -> URL {
        booksDirectory.appendingPathComponent("\(uuid)_\(category)", isDirectory: true)
    }

    private func getChunkDirectory(uuid: String, category: String) -> URL {
        chunksDirectory.appendingPathComponent("\(uuid)_\(category)", isDirectory: true)
    }

    private func getChunkManifestURL(uuid: String, category: String) -> URL {
        getChunkDirectory(uuid: uuid, category: category).appendingPathComponent("manifest.json")
    }

    public func receiveChunk(from sourceURL: URL, metadata: ChunkTransferMetadata) -> Bool {
        let chunkDir = getChunkDirectory(uuid: metadata.uuid, category: metadata.category)

        do {
            try fileManager.createDirectory(at: chunkDir, withIntermediateDirectories: true)

            let chunkFileName = "chunk_\(String(format: "%03d", metadata.chunkIndex))"
            let destURL = chunkDir.appendingPathComponent(chunkFileName)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destURL)

            var manifest = loadOrCreateManifest(
                uuid: metadata.uuid,
                category: metadata.category,
                metadata: metadata
            )
            manifest.receivedChunks.insert(metadata.chunkIndex)
            saveManifest(manifest, uuid: metadata.uuid, category: metadata.category)

            print(
                "[WatchStorageManager] Saved chunk \(metadata.chunkIndex + 1)/\(metadata.totalChunks)"
            )

            if manifest.receivedChunks.count == metadata.totalChunks {
                return assembleChunks(
                    uuid: metadata.uuid,
                    category: metadata.category,
                    manifest: manifest
                )
            }

            return false

        } catch {
            print("[WatchStorageManager] Failed to save chunk: \(error)")
            return false
        }
    }

    private func loadOrCreateManifest(
        uuid: String,
        category: String,
        metadata: ChunkTransferMetadata
    ) -> TransferManifest {
        let manifestURL = getChunkManifestURL(uuid: uuid, category: category)

        if fileManager.fileExists(atPath: manifestURL.path),
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(TransferManifest.self, from: data)
        {
            return manifest
        }

        return TransferManifest(
            uuid: metadata.uuid,
            title: metadata.title,
            authors: metadata.authors,
            category: metadata.category,
            totalChunks: metadata.totalChunks,
            totalFileSize: metadata.totalFileSize,
            fileExtension: metadata.fileExtension,
            receivedChunks: []
        )
    }

    private func saveManifest(_ manifest: TransferManifest, uuid: String, category: String) {
        let manifestURL = getChunkManifestURL(uuid: uuid, category: category)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    private func assembleChunks(uuid: String, category: String, manifest: TransferManifest) -> Bool
    {
        let chunkDir = getChunkDirectory(uuid: uuid, category: category)
        let bookDir = getBookDirectory(uuid: uuid, category: category)

        do {
            try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)

            let fileName = "book.\(manifest.fileExtension)"
            let destURL = bookDir.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            fileManager.createFile(atPath: destURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: destURL)
            defer { try? outputHandle.close() }

            var totalWritten: Int64 = 0
            for chunkIndex in 0..<manifest.totalChunks {
                let chunkFileName = "chunk_\(String(format: "%03d", chunkIndex))"
                let chunkURL = chunkDir.appendingPathComponent(chunkFileName)

                let chunkData = try Data(contentsOf: chunkURL)
                try outputHandle.write(contentsOf: chunkData)
                totalWritten += Int64(chunkData.count)
            }

            print("[WatchStorageManager] Assembled file: \(fileName), size: \(totalWritten) bytes")

            let entry = WatchBookEntry(
                uuid: manifest.uuid,
                title: manifest.title,
                authors: manifest.authors,
                category: manifest.category,
                addedAt: Date()
            )
            saveBookEntry(entry)

            try? fileManager.removeItem(at: chunkDir)

            return true

        } catch {
            print("[WatchStorageManager] Failed to assemble chunks: \(error)")
            return false
        }
    }

    public func cancelChunkedTransfer(uuid: String, category: String) {
        let chunkDir = getChunkDirectory(uuid: uuid, category: category)
        try? fileManager.removeItem(at: chunkDir)
        print("[WatchStorageManager] Cancelled transfer for \(uuid)_\(category)")
    }

    public func saveBookEntry(_ entry: WatchBookEntry) {
        var entries = loadAllBooks()
        entries.removeAll { $0.uuid == entry.uuid && $0.category == entry.category }
        entries.append(entry)

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: libraryFile)
        } catch {
            print("[WatchStorageManager] Failed to save library: \(error)")
        }
    }

    public func loadAllBooks() -> [WatchBookEntry] {
        guard fileManager.fileExists(atPath: libraryFile.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: libraryFile)
            return try JSONDecoder().decode([WatchBookEntry].self, from: data)
        } catch {
            print("[WatchStorageManager] Failed to load library: \(error)")
            return []
        }
    }

    public func deleteBook(uuid: String, category: String) {
        let bookDir = getBookDirectory(uuid: uuid, category: category)
        try? fileManager.removeItem(at: bookDir)

        let chunkDir = getChunkDirectory(uuid: uuid, category: category)
        try? fileManager.removeItem(at: chunkDir)

        var entries = loadAllBooks()
        entries.removeAll { $0.uuid == uuid && $0.category == category }

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: libraryFile)
        } catch {
            print("[WatchStorageManager] Failed to update library after delete: \(error)")
        }
    }

    public func getBookSize(uuid: String, category: String) -> Int64 {
        let bookDir = getBookDirectory(uuid: uuid, category: category)
        return directorySize(at: bookDir)
    }

    private func directorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                let fileSize = attrs.fileSize
            else { continue }
            size += Int64(fileSize)
        }

        return size
    }

    public func getBookFilePath(uuid: String, category: String) -> URL? {
        let bookDir = getBookDirectory(uuid: uuid, category: category)
        guard fileManager.fileExists(atPath: bookDir.path) else { return nil }

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: bookDir,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }

        return contents.first { $0.lastPathComponent.hasPrefix("book.") }
    }

    public func cleanupOrphanedFiles() {
        let knownIds = Set(loadAllBooks().map { "\($0.uuid)_\($0.category)" })

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: booksDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return }

        for item in contents {
            guard let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                resourceValues.isDirectory == true
            else { continue }

            let dirName = item.lastPathComponent
            if !knownIds.contains(dirName) {
                print("[WatchStorageManager] Removing orphaned book directory: \(dirName)")
                try? fileManager.removeItem(at: item)
            }
        }

        if let chunkContents = try? fileManager.contentsOfDirectory(
            at: chunksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for item in chunkContents {
                print(
                    "[WatchStorageManager] Removing orphaned chunk directory: \(item.lastPathComponent)"
                )
                try? fileManager.removeItem(at: item)
            }
        }
    }
}

public struct WatchBookEntry: Identifiable, Codable, Sendable, Hashable {
    public let uuid: String
    public let title: String
    public let authors: [String]
    public let category: String
    public let addedAt: Date

    public var id: String { "\(uuid)_\(category)" }

    public var authorDisplay: String {
        authors.joined(separator: ", ")
    }
}

struct TransferManifest: Codable {
    let uuid: String
    let title: String
    let authors: [String]
    let category: String
    let totalChunks: Int
    let totalFileSize: Int64
    let fileExtension: String
    var receivedChunks: Set<Int>
}

public struct ChunkTransferMetadata: Codable, Sendable {
    public let uuid: String
    public let title: String
    public let authors: [String]
    public let category: String
    public let chunkIndex: Int
    public let totalChunks: Int
    public let totalFileSize: Int64
    public let fileExtension: String
}
