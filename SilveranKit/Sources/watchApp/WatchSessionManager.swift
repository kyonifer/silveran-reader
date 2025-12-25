import Foundation
import SilveranKitCommon
import WatchConnectivity

public final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSessionManager()

    private var session: WCSession?

    nonisolated(unsafe) var onTransferProgress: ((String, Int, Int) -> Void)?
    nonisolated(unsafe) var onTransferComplete: (() -> Void)?
    nonisolated(unsafe) var onBookDeleted: (() -> Void)?
    nonisolated(unsafe) var onPlaybackStateReceived: ((RemotePlaybackState?) -> Void)?
    nonisolated(unsafe) var onCredentialsReceived: ((String, String, String) -> Void)?

    private override init() {
        super.init()
    }

    public var isPhoneReachable: Bool {
        session?.isReachable ?? false
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let wcSession = WCSession.default
        wcSession.delegate = self
        wcSession.activate()
        session = wcSession
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("[WatchSessionManager] Activation error: \(error)")
        } else {
            print("[WatchSessionManager] Session activated: \(activationState.rawValue)")
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message, replyHandler: nil)
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
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
            case "playbackState":
                handlePlaybackState(message)
                replyHandler?(["status": "ok"])
            case "credentialsSync":
                handleCredentialsSync(message, replyHandler: replyHandler)
            default:
                replyHandler?(["error": "Unhandled message type: \(type)"])
        }
    }

    private func handlePlaybackState(_ message: [String: Any]) {
        if let stateData = message["state"] as? Data {
            do {
                let state = try JSONDecoder().decode(RemotePlaybackState.self, from: stateData)
                onPlaybackStateReceived?(state)
            } catch {
                print("[WatchSessionManager] Failed to decode playback state: \(error)")
                onPlaybackStateReceived?(nil)
            }
        } else {
            onPlaybackStateReceived?(nil)
        }
    }

    private func handleDeleteBook(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) {
        guard let uuid = message["uuid"] as? String,
            let category = message["category"] as? String
        else {
            replyHandler?(["error": "Missing uuid or category"])
            return
        }

        WatchStorageManager.shared.deleteBook(uuid: uuid, category: category)
        onBookDeleted?()
        replyHandler?(["status": "ok"])
    }

    private func handleCancelTransfer(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) {
        guard let uuid = message["uuid"] as? String,
            let category = message["category"] as? String
        else {
            replyHandler?(["error": "Missing uuid or category"])
            return
        }

        WatchStorageManager.shared.cancelChunkedTransfer(uuid: uuid, category: category)
        replyHandler?(["status": "ok"])
    }

    private func handleCredentialsSync(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) {
        guard let url = message["url"] as? String,
            let username = message["username"] as? String,
            let password = message["password"] as? String
        else {
            replyHandler?(["error": "Missing credentials fields"])
            return
        }

        print("[WatchSessionManager] Received credentials from iPhone")

        Task {
            do {
                try await AuthenticationActor.shared.saveCredentials(
                    url: url,
                    username: username,
                    password: password
                )
                print("[WatchSessionManager] Credentials saved to keychain")
                onCredentialsReceived?(url, username, password)
            } catch {
                print("[WatchSessionManager] Failed to save credentials: \(error)")
            }
        }

        replyHandler?(["status": "ok"])
    }

    public func requestCredentialsFromPhone() {
        guard let session, session.isReachable else {
            print("[WatchSessionManager] iPhone not reachable for credentials request")
            return
        }

        let message: [String: Any] = ["type": "requestCredentials"]
        session.sendMessage(
            message,
            replyHandler: { [weak self] reply in
                guard let url = reply["url"] as? String,
                    let username = reply["username"] as? String,
                    let password = reply["password"] as? String
                else {
                    print("[WatchSessionManager] Invalid credentials reply from iPhone")
                    return
                }

                let callback = self?.onCredentialsReceived
                Task { @MainActor in
                    do {
                        try await AuthenticationActor.shared.saveCredentials(
                            url: url,
                            username: username,
                            password: password
                        )
                        print("[WatchSessionManager] Credentials received and saved")
                        callback?(url, username, password)
                    } catch {
                        print("[WatchSessionManager] Failed to save received credentials: \(error)")
                    }
                }
            },
            errorHandler: { error in
                print("[WatchSessionManager] Failed to request credentials: \(error)")
            }
        )
    }

    private func handleLibraryRequest(replyHandler: (([String: Any]) -> Void)?) {
        let books = WatchStorageManager.shared.loadAllBooks()
        let bookInfos = books.map { book in
            WatchBookInfoResponse(
                id: book.uuid,
                title: book.title,
                authorNames: book.authors,
                category: book.category,
                sizeBytes: WatchStorageManager.shared.getBookSize(
                    uuid: book.uuid,
                    category: book.category
                )
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
        print(
            "[WatchSessionManager] didReceive file called! URL: \(file.fileURL.lastPathComponent)"
        )
        print(
            "[WatchSessionManager] metadata keys: \(file.metadata?.keys.joined(separator: ", ") ?? "none")"
        )

        guard let fileMetadata = file.metadata,
            let metadataData = fileMetadata["chunkMetadata"] as? Data
        else {
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

        print(
            "[WatchSessionManager] Received chunk \(chunkMetadata.chunkIndex + 1)/\(chunkMetadata.totalChunks) for: \(chunkMetadata.title) [\(chunkMetadata.category)]"
        )

        let isComplete = WatchStorageManager.shared.receiveChunk(
            from: file.fileURL,
            metadata: chunkMetadata
        )

        onTransferProgress?(
            chunkMetadata.title,
            chunkMetadata.chunkIndex + 1,
            chunkMetadata.totalChunks
        )

        if isComplete {
            print(
                "[WatchSessionManager] All chunks received for: \(chunkMetadata.title) [\(chunkMetadata.category)]"
            )
            onTransferComplete?()
            notifyPhone(bookUUID: chunkMetadata.uuid, category: chunkMetadata.category)
        }
    }

    private func notifyPhone(bookUUID: String, category: String) {
        guard let session else { return }
        let message: [String: Any] = [
            "type": "transferComplete",
            "uuid": bookUUID,
            "category": category,
        ]
        // Use transferUserInfo instead of sendMessage - it queues for background
        // delivery even when the phone is asleep, whereas sendMessage requires
        // active reachability and silently fails otherwise
        session.transferUserInfo(message)
        print("[WatchSessionManager] Queued transferComplete via transferUserInfo for \(bookUUID)")
    }

    // MARK: - Remote Playback Control

    public func requestPlaybackState() {
        guard let session, session.isReachable else {
            print("[WatchSessionManager] iPhone not reachable for playback state request")
            onPlaybackStateReceived?(nil)
            return
        }

        let message: [String: Any] = ["type": "requestPlaybackState"]
        session.sendMessage(
            message,
            replyHandler: { [weak self] reply in
                if let stateData = reply["state"] as? Data {
                    do {
                        let state = try JSONDecoder().decode(
                            RemotePlaybackState.self,
                            from: stateData
                        )
                        self?.onPlaybackStateReceived?(state)
                    } catch {
                        print(
                            "[WatchSessionManager] Failed to decode playback state reply: \(error)"
                        )
                        self?.onPlaybackStateReceived?(nil)
                    }
                } else {
                    self?.onPlaybackStateReceived?(nil)
                }
            },
            errorHandler: { error in
                print("[WatchSessionManager] Failed to request playback state: \(error)")
                self.onPlaybackStateReceived?(nil)
            }
        )
    }

    public func sendPlaybackCommand(_ command: RemotePlaybackCommand) {
        guard let session, session.isReachable else {
            print("[WatchSessionManager] iPhone not reachable for playback command")
            return
        }

        var message: [String: Any] = ["type": "playbackControl"]

        switch command {
            case .togglePlayPause:
                message["command"] = "togglePlayPause"
            case .skipForward:
                message["command"] = "skipForward"
            case .skipBackward:
                message["command"] = "skipBackward"
            case .seekToChapter(let sectionIndex):
                message["command"] = "seekToChapter"
                message["value"] = sectionIndex
            case .setPlaybackRate(let rate):
                message["command"] = "setPlaybackRate"
                message["value"] = rate
            case .setVolume(let volume):
                message["command"] = "setVolume"
                message["value"] = volume
        }

        session.sendMessage(
            message,
            replyHandler: nil,
            errorHandler: { error in
                print("[WatchSessionManager] Failed to send playback command: \(error)")
            }
        )
    }
}

private struct WatchBookInfoResponse: Codable {
    let id: String
    let title: String
    let authorNames: [String]
    let category: String
    let sizeBytes: Int64
}
