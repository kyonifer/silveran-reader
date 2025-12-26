import Foundation
import SilveranKitCommon

public final class WatchStorageManager: Sendable {
    public static let shared = WatchStorageManager()

    private var fileManager: FileManager { FileManager.default }

    private var chunksDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("chunks", isDirectory: true)
    }

    private init() {
        ensureDirectoriesExist()
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
    }

    private func getChunkDirectory(uuid: String, category: String) -> URL {
        chunksDirectory.appendingPathComponent("\(uuid)_\(category)", isDirectory: true)
    }

    private func getChunkManifestURL(uuid: String, category: String) -> URL {
        getChunkDirectory(uuid: uuid, category: category).appendingPathComponent("manifest.json")
    }

    public struct ChunkResult {
        public let isComplete: Bool
        public let manifest: TransferManifest?
    }

    public func receiveChunk(from sourceURL: URL, metadata: ChunkTransferMetadata) -> ChunkResult {
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
                return ChunkResult(isComplete: true, manifest: manifest)
            }

            return ChunkResult(isComplete: false, manifest: nil)

        } catch {
            print("[WatchStorageManager] Failed to save chunk: \(error)")
            return ChunkResult(isComplete: false, manifest: nil)
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
            var manifest = try? JSONDecoder().decode(TransferManifest.self, from: data)
        {
            if manifest.bookMetadata == nil, let bookMeta = metadata.bookMetadata {
                manifest.bookMetadata = bookMeta
            }
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
            receivedChunks: [],
            bookMetadata: metadata.bookMetadata
        )
    }

    private func saveManifest(_ manifest: TransferManifest, uuid: String, category: String) {
        let manifestURL = getChunkManifestURL(uuid: uuid, category: category)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    public func assembleChunksToTempFile(manifest: TransferManifest) -> URL? {
        let chunkDir = getChunkDirectory(uuid: manifest.uuid, category: manifest.category)
        let tempDir = fileManager.temporaryDirectory
        let fileName = "book.\(manifest.fileExtension)"
        let destURL = tempDir.appendingPathComponent("\(manifest.uuid)_\(fileName)")

        do {
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

            try? fileManager.removeItem(at: chunkDir)

            return destURL

        } catch {
            print("[WatchStorageManager] Failed to assemble chunks: \(error)")
            return nil
        }
    }

    public func cancelChunkedTransfer(uuid: String, category: String) {
        let chunkDir = getChunkDirectory(uuid: uuid, category: category)
        try? fileManager.removeItem(at: chunkDir)
        print("[WatchStorageManager] Cancelled transfer for \(uuid)_\(category)")
    }
}

public struct TransferManifest: Codable {
    public let uuid: String
    public let title: String
    public let authors: [String]
    public let category: String
    public let totalChunks: Int
    public let totalFileSize: Int64
    public let fileExtension: String
    public var receivedChunks: Set<Int>
    public var bookMetadata: BookMetadata?
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
    public let bookMetadata: BookMetadata?
}
