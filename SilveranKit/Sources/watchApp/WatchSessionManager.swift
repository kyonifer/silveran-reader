import Foundation
import WatchConnectivity

public final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSessionManager()

    private var session: WCSession?

    nonisolated(unsafe) var onTransferProgress: ((String, Int, Int) -> Void)?
    nonisolated(unsafe) var onTransferComplete: (() -> Void)?
    nonisolated(unsafe) var onBookDeleted: (() -> Void)?

    private override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let wcSession = WCSession.default
        wcSession.delegate = self
        wcSession.activate()
        session = wcSession
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[WatchSessionManager] Activation error: \(error)")
        } else {
            print("[WatchSessionManager] Session activated: \(activationState.rawValue)")
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleMessage(message, replyHandler: nil)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        handleMessage(message, replyHandler: replyHandler)
    }

    private func handleMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let type = message["type"] as? String else {
            replyHandler?(["error": "Unknown message type"])
            return
        }

        switch type {
        case "deleteBook":
            handleDeleteBook(message, replyHandler: replyHandler)
        case "requestLibrary":
            handleLibraryRequest(replyHandler: replyHandler)
        case "cancelTransfer":
            handleCancelTransfer(message, replyHandler: replyHandler)
        default:
            replyHandler?(["error": "Unhandled message type: \(type)"])
        }
    }

    private func handleDeleteBook(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let uuid = message["uuid"] as? String,
              let category = message["category"] as? String else {
            replyHandler?(["error": "Missing uuid or category"])
            return
        }

        WatchStorageManager.shared.deleteBook(uuid: uuid, category: category)
        onBookDeleted?()
        replyHandler?(["status": "ok"])
    }

    private func handleCancelTransfer(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let uuid = message["uuid"] as? String,
              let category = message["category"] as? String else {
            replyHandler?(["error": "Missing uuid or category"])
            return
        }

        WatchStorageManager.shared.cancelChunkedTransfer(uuid: uuid, category: category)
        replyHandler?(["status": "ok"])
    }

    private func handleLibraryRequest(replyHandler: (([String: Any]) -> Void)?) {
        let books = WatchStorageManager.shared.loadAllBooks()
        let bookInfos = books.map { book in
            WatchBookInfoResponse(
                id: book.uuid,
                title: book.title,
                authorNames: book.authors,
                category: book.category,
                sizeBytes: WatchStorageManager.shared.getBookSize(uuid: book.uuid, category: book.category)
            )
        }

        do {
            let data = try JSONEncoder().encode(bookInfos)
            replyHandler?(["books": data])
        } catch {
            replyHandler?(["error": "Failed to encode library"])
        }
    }

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("[WatchSessionManager] didReceive file called! URL: \(file.fileURL.lastPathComponent)")
        print("[WatchSessionManager] metadata keys: \(file.metadata?.keys.joined(separator: ", ") ?? "none")")

        guard let fileMetadata = file.metadata,
              let metadataData = fileMetadata["chunkMetadata"] as? Data else {
            print("[WatchSessionManager] Received file with no chunk metadata")
            return
        }

        let chunkMetadata: ChunkTransferMetadata
        do {
            chunkMetadata = try JSONDecoder().decode(ChunkTransferMetadata.self, from: metadataData)
        } catch {
            print("[WatchSessionManager] Failed to decode chunk metadata: \(error)")
            return
        }

        print("[WatchSessionManager] Received chunk \(chunkMetadata.chunkIndex + 1)/\(chunkMetadata.totalChunks) for: \(chunkMetadata.title) [\(chunkMetadata.category)]")

        let isComplete = WatchStorageManager.shared.receiveChunk(
            from: file.fileURL,
            metadata: chunkMetadata
        )

        onTransferProgress?(chunkMetadata.title, chunkMetadata.chunkIndex + 1, chunkMetadata.totalChunks)

        if isComplete {
            print("[WatchSessionManager] All chunks received for: \(chunkMetadata.title) [\(chunkMetadata.category)]")
            onTransferComplete?()
            notifyPhone(bookUUID: chunkMetadata.uuid, category: chunkMetadata.category)
        }
    }

    private func notifyPhone(bookUUID: String, category: String) {
        guard let session else { return }
        let message: [String: Any] = [
            "type": "transferComplete",
            "uuid": bookUUID,
            "category": category
        ]
        // Use transferUserInfo instead of sendMessage - it queues for background
        // delivery even when the phone is asleep, whereas sendMessage requires
        // active reachability and silently fails otherwise
        session.transferUserInfo(message)
        print("[WatchSessionManager] Queued transferComplete via transferUserInfo for \(bookUUID)")
    }
}

private struct WatchBookInfoResponse: Codable {
    let id: String
    let title: String
    let authorNames: [String]
    let category: String
    let sizeBytes: Int64
}
