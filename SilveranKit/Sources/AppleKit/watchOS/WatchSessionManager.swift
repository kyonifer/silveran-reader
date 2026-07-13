#if os(watchOS)
import Foundation
import SilveranKit
import WatchConnectivity

public final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSessionManager()

    private var session: WCSession?
    nonisolated(unsafe) private var cachedBookInfos: [WatchBookInfoResponse] = []

    nonisolated(unsafe) var onTransferProgress: ((String, Int, Int) -> Void)?
    nonisolated(unsafe) var onTransferComplete: ((String, String) -> Void)?  // (uuid, title)
    nonisolated(unsafe) var onImportComplete: ((Bool) -> Void)?  // success
    nonisolated(unsafe) var onBookDeleted: (() -> Void)?
    nonisolated(unsafe) var onPlaybackStateReceived: ((RemotePlaybackState?) -> Void)?
    nonisolated(unsafe) var onCredentialsReceived: ((String, String, String) -> Void)?

    private override init() {
        super.init()
    }

    public func refreshCachedBooks() {
        Task {
            let books = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly).books
            cachedBookInfos = books.map { book in
                WatchBookInfoResponse(
                    id: book.uuid,
                    title: book.title,
                    authorNames: book.authors?.compactMap { $0.name } ?? [],
                    category: "synced",
                    sizeBytes: 0,
                )
            }
        }
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
        refreshCachedBooks()
        Task {
            _ = await ProgressSyncActor.shared.addObserver {
                Task { await WatchSessionManager.shared.relayPendingProgress() }
            }
        }
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?,
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
        replyHandler: @escaping ([String: Any]) -> Void,
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
        replyHandler: (([String: Any]) -> Void)?,
    ) {
        guard let uuid = message["uuid"] as? String,
            let sourceID = message["sourceID"] as? BookSourceID,
            let categoryString = message["category"] as? String
        else {
            replyHandler?(["error": "Missing book identity or category"])
            return
        }

        let category: LocalMediaCategory = categoryString == "synced" ? .synced : .ebook

        Task {
            try? await BookServiceActor.shared.deleteCachedMedia(
                for: BookID(sourceID: sourceID, uuid: uuid),
                category: category,
            )
            refreshCachedBooks()
            await MainActor.run {
                onBookDeleted?()
            }
        }
        replyHandler?(["status": "ok"])
    }

    private func handleCancelTransfer(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
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

    public func requestCredentialsFromPhone(sourceID: BookSourceID?) {
        guard let session, session.isReachable else {
            print("[WatchSessionManager] iPhone not reachable for credentials request")
            return
        }

        var message: [String: Any] = ["type": "requestCredentials"]
        if let sourceID {
            message["sourceID"] = sourceID
        }
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
                    callback?(url, username, password)
                }
            },
            errorHandler: { error in
                print("[WatchSessionManager] Failed to request credentials: \(error)")
            },
        )
    }

    private func handleLibraryRequest(replyHandler: (([String: Any]) -> Void)?) {
        do {
            let data = try JSONEncoder().encode(cachedBookInfos)
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
            chunkMetadata = try JSONDecoder().decode(
                ChunkTransferMetadata.self,
                from: metadataData,
            )
        } catch {
            print("[WatchSessionManager] Failed to decode chunk metadata: \(error)")
            return
        }

        print(
            "[WatchSessionManager] Received chunk \(chunkMetadata.chunkIndex + 1)/\(chunkMetadata.totalChunks) for: \(chunkMetadata.title) [\(chunkMetadata.category)]"
        )

        let result = WatchStorageManager.shared.receiveChunk(
            from: file.fileURL,
            metadata: chunkMetadata,
        )

        onTransferProgress?(
            chunkMetadata.title,
            chunkMetadata.chunkIndex + 1,
            chunkMetadata.totalChunks,
        )

        if result.isComplete, let manifest = result.manifest {
            print(
                "[WatchSessionManager] All chunks received for: \(chunkMetadata.title) [\(chunkMetadata.category)]"
            )

            onTransferComplete?(chunkMetadata.uuid, chunkMetadata.title)

            Task {
                let success = await importTransferredBook(manifest: manifest)
                await MainActor.run {
                    onImportComplete?(success)
                }
            }

            notifyPhone(bookUUID: chunkMetadata.uuid, category: chunkMetadata.category)
        }
    }

    private func importTransferredBook(manifest: TransferManifest) async -> Bool {
        guard let tempURL = WatchStorageManager.shared.assembleChunksToTempFile(manifest: manifest)
        else {
            print("[WatchSessionManager] Failed to assemble chunks")
            return false
        }

        let category: LocalMediaCategory = manifest.category == "synced" ? .synced : .ebook

        let bookMetadata: BookMetadata
        if let transferredMetadata = manifest.bookMetadata {
            bookMetadata = transferredMetadata
        } else {
            guard let sourceID = manifest.sourceID else {
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
            let authors: [BookCreator] = manifest.authors.map { name in
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: name,
                    fileAs: nil,
                    role: nil,
                    createdAt: nil,
                    updatedAt: nil,
                )
            }
            bookMetadata = BookMetadata(
                bookID: BookID(sourceID: sourceID, uuid: manifest.uuid),
                title: manifest.title,
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
                audiobook: nil,
                readaloud: nil,
                status: nil,
                position: nil,
                rating: nil,
            )
        }

        do {
            await mergeBookMetadataIntoLMA(bookMetadata)

            try await BookServiceActor.shared.importDownloadedFileToCache(
                from: tempURL,
                metadata: bookMetadata,
                category: category,
                filename: "book.\(manifest.fileExtension)",
            )
            print("[WatchSessionManager] Imported book to LMA: \(manifest.title)")
            refreshCachedBooks()
            return true
        } catch {
            print("[WatchSessionManager] Failed to import book to LMA: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    private func mergeBookMetadataIntoLMA(_ book: BookMetadata) async {
        var current = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly).books
            .filter { $0.sourceID == book.sourceID }

        if let idx = current.firstIndex(where: { $0.id == book.id }) {
            if isNewer(book, than: current[idx]) {
                current[idx] = book
            }
        } else {
            current.append(book)
        }

        try? await BookServiceActor.shared.updateLibraryCacheMetadata(
            current,
            replacingSourceID: book.sourceID,
        )
    }

    private func isNewer(_ newBook: BookMetadata, than existingBook: BookMetadata) -> Bool {
        // Prioritize position timestamp comparison for reading progress
        let newPositionTimestamp = newBook.position?.timestamp ?? 0
        let existingPositionTimestamp = existingBook.position?.timestamp ?? 0

        if newPositionTimestamp != 0 || existingPositionTimestamp != 0 {
            return newPositionTimestamp > existingPositionTimestamp
        }

        // Fallback to book metadata updatedAt for non-position data
        guard let newDateStr = newBook.updatedAt else { return false }
        guard let existingDateStr = existingBook.updatedAt else { return true }
        return newDateStr > existingDateStr
    }

    public func requestLibraryMetadataFromPhone() async -> Bool {
        guard let session, session.isReachable else {
            print("[WatchSessionManager] iPhone not reachable for library metadata request")
            return false
        }

        return await withCheckedContinuation { continuation in
            let message: [String: Any] = ["type": "requestLibraryMetadata"]
            session.sendMessage(
                message,
                replyHandler: { [weak self] reply in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.handleLibraryMetadataReply(reply, continuation: continuation)
                },
                errorHandler: { error in
                    print("[WatchSessionManager] Failed to request library metadata: \(error)")
                    continuation.resume(returning: false)
                },
            )
        }
    }

    private func handleLibraryMetadataReply(
        _ reply: [String: Any],
        continuation: CheckedContinuation<Bool, Never>,
    ) {
        guard let metadataData = reply["metadata"] as? Data else {
            print("[WatchSessionManager] No metadata in phone reply")
            continuation.resume(returning: false)
            return
        }

        do {
            let phoneMetadata = try JSONDecoder().decode([BookMetadata].self, from: metadataData)
            Task {
                await self.mergePhoneMetadataIntoLMA(phoneMetadata)
                print("[WatchSessionManager] Merged \(phoneMetadata.count) books from iPhone")
                continuation.resume(returning: true)
            }
        } catch {
            print("[WatchSessionManager] Failed to decode phone metadata: \(error)")
            continuation.resume(returning: false)
        }
    }

    private func mergePhoneMetadataIntoLMA(_ phoneBooks: [BookMetadata]) async {
        let cached = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly).books

        for (sourceID, incoming) in Dictionary(grouping: phoneBooks, by: \.sourceID) {
            var current = cached.filter { $0.sourceID == sourceID }
            for phoneBook in incoming {
                if let idx = current.firstIndex(where: { $0.id == phoneBook.id }) {
                    if isNewer(phoneBook, than: current[idx]) {
                        current[idx] = phoneBook
                    }
                } else {
                    current.append(phoneBook)
                }
            }
            try? await BookServiceActor.shared.updateLibraryCacheMetadata(
                current,
                replacingSourceID: sourceID,
            )
        }
    }

    public func relayPendingProgress() async {
        guard let session, session.activationState == .activated else { return }

        let pending = await ProgressSyncActor.shared.getPendingProgressSyncs()
            .filter { !$0.syncedToStoryteller }
        guard !pending.isEmpty else { return }

        let outstanding = session.outstandingUserInfoTransfers

        for item in pending {
            var alreadyQueued = false
            for transfer in outstanding {
                guard
                    transfer.userInfo[WatchProgressRelayMessage.typeKey] as? String
                        == WatchProgressRelayMessage.type,
                    let queuedData = transfer.userInfo[WatchProgressRelayMessage.payloadKey]
                        as? Data,
                    let queued = try? JSONDecoder().decode(
                        WatchProgressRelayPayload.self,
                        from: queuedData,
                    ),
                    queued.bookId == item.bookID.uuid,
                    queued.sourceID == item.bookID.sourceID
                else { continue }
                let queuedTimestamp =
                    transfer.userInfo[WatchProgressRelayMessage.timestampKey] as? Double ?? 0
                if queuedTimestamp >= item.timestamp {
                    alreadyQueued = true
                } else {
                    transfer.cancel()
                }
            }
            if alreadyQueued { continue }

            let payload = WatchProgressRelayPayload(
                bookId: item.bookID.uuid,
                sourceID: item.bookID.sourceID,
                locator: item.locator,
                timestamp: item.timestamp,
            )
            guard let payloadData = try? JSONEncoder().encode(payload) else {
                print("[WatchSessionManager] Failed to encode progress relay for \(item.bookID)")
                continue
            }

            // transferUserInfo queues persistently and delivers in the background
            // when the phone is in range, even if both apps are terminated
            session.transferUserInfo([
                WatchProgressRelayMessage.typeKey: WatchProgressRelayMessage.type,
                WatchProgressRelayMessage.bookIdKey: item.bookID.uuid,
                WatchProgressRelayMessage.timestampKey: item.timestamp,
                WatchProgressRelayMessage.payloadKey: payloadData,
            ])
            print(
                "[WatchSessionManager] Queued progress relay for \(item.bookID) ts=\(item.timestamp)"
            )
        }
    }

    public func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?,
    ) {
        guard let error else { return }
        let type = userInfoTransfer.userInfo[WatchProgressRelayMessage.typeKey] as? String
        print(
            "[WatchSessionManager] userInfo transfer failed (type: \(type ?? "unknown")): \(error)"
        )
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
                            from: stateData,
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
            },
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
            },
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
#endif
