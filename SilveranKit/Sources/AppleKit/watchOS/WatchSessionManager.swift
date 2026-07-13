#if os(watchOS)
import Foundation
import SilveranKit
import WatchConnectivity

public final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSessionManager()

    private var session: WCSession?
    nonisolated(unsafe) private var cachedBookInfos: [WatchBookInfo] = []

    nonisolated(unsafe) var onTransferProgress: ((String, Int, Int) -> Void)?
    nonisolated(unsafe) var onTransferComplete: ((BookID, String) -> Void)?
    nonisolated(unsafe) var onImportComplete: ((Bool) -> Void)?
    nonisolated(unsafe) var onBookDeleted: (() -> Void)?
    nonisolated(unsafe) var onPlaybackStateReceived: ((RemotePlaybackState?) -> Void)?
    nonisolated(unsafe) var onCredentialSourcesReceived:
        (([WatchCredentialSourceInfo]) -> Void)?
    nonisolated(unsafe) var onCredentialsReceived: ((WatchCredentialReply) -> Void)?

    private override init() {
        super.init()
    }

    public var isPhoneReachable: Bool {
        guard let session, session.isReachable else { return false }
        return protocolContext(from: session.receivedApplicationContext) != nil
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

    public func refreshCachedBooks() {
        Task {
            let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
            cachedBookInfos = snapshot.books.flatMap { book -> [WatchBookInfo] in
                guard let paths = snapshot.cachedMediaPaths[book.id] else { return [] }
                let categories: [LocalMediaCategory] = [
                    paths.ebookPath == nil ? nil : .ebook,
                    paths.audioPath == nil ? nil : .audio,
                    paths.syncedPath == nil ? nil : .synced,
                ].compactMap { $0 }
                return categories.map { category in
                    WatchBookInfo(
                        bookID: book.id,
                        title: book.title,
                        authorNames: book.authors?.compactMap(\.name) ?? [],
                        category: category,
                        sizeBytes: 0,
                    )
                }
            }
        }
    }

    public func publishProtocolContext() async {
        guard let session else { return }
        let sourceIDs = await BookServiceActor.shared.bookSources
            .filter { $0.kind == .storyteller }
            .map(\.id)
            .sorted()
        do {
            try session.updateApplicationContext(
                try WatchProtocolMessage.context(
                    WatchProtocolContext(sourceIDs: sourceIDs)
                ).encode()
            )
        } catch {
            print("[WatchSessionManager] Failed to publish protocol context: \(error)")
        }
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?,
    ) {
        if let error {
            print("[WatchSessionManager] Activation error: \(error)")
            return
        }
        guard activationState == .activated else { return }
        Task { await publishProtocolContext() }
    }

    public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any],
    ) {
        guard protocolContext(from: applicationContext) != nil else {
            print("[WatchSessionManager] Ignored non-v2 application context")
            return
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleEnvelope(message, replyHandler: nil)
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void,
    ) {
        handleEnvelope(message, replyHandler: replyHandler)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleEnvelope(userInfo, replyHandler: nil)
    }

    private func handleEnvelope(
        _ envelope: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
    ) {
        let message: WatchProtocolMessage
        do {
            message = try WatchProtocolMessage.decode(from: envelope)
        } catch {
            reply(.failure(WatchFailure(message: "Watch protocol v2 required")), to: replyHandler)
            return
        }

        if case .cancelTransfer(let reference) = message {
            WatchStorageManager.shared.cancelChunkedTransfer(
                transferID: reference.transferID
            )
            reply(.acknowledgement, to: replyHandler)
            return
        }

        guard canSendToPhone else {
            reply(.failure(WatchFailure(message: "Watch protocol v2 required")), to: replyHandler)
            return
        }

        switch message {
            case .deleteBook(let payload):
                handleDeleteBook(payload, replyHandler: replyHandler)
            case .cancelTransfer:
                return
            case .watchLibraryRequest:
                reply(
                    .watchLibrary(WatchLibrary(books: cachedBookInfos)),
                    to: replyHandler,
                )
            case .playbackState(let state):
                onPlaybackStateReceived?(state)
                reply(.acknowledgement, to: replyHandler)
            case .noPlaybackState:
                onPlaybackStateReceived?(nil)
                reply(.acknowledgement, to: replyHandler)
            case .ping:
                reply(.pong, to: replyHandler)
            default:
                reply(
                    .failure(WatchFailure(message: "Unsupported watch message")),
                    to: replyHandler,
                )
        }
    }

    private func handleDeleteBook(
        _ payload: WatchDeleteBookPayload,
        replyHandler: (([String: Any]) -> Void)?,
    ) {
        let sendableReply = replyHandler.map(SendableWatchReplyHandler.init)
        Task {
            let sourceIDs = Set(
                await BookServiceActor.shared.bookSources
                    .filter { $0.kind == .storyteller }
                    .map(\.id)
            )
            guard sourceIDs.contains(payload.bookID.sourceID) else {
                sendableReply?.reply(
                    try? WatchProtocolMessage.failure(
                        WatchFailure(message: "Unknown book source")
                    ).encode()
                )
                return
            }

            do {
                try await BookServiceActor.shared.deleteCachedMedia(
                    for: payload.bookID,
                    category: payload.category,
                )
                refreshCachedBooks()
                await MainActor.run { onBookDeleted?() }
                sendableReply?.reply(try? WatchProtocolMessage.acknowledgement.encode())
            } catch {
                sendableReply?.reply(
                    try? WatchProtocolMessage.failure(
                        WatchFailure(message: error.localizedDescription)
                    ).encode()
                )
            }
        }
    }

    public func requestCredentialSourcesFromPhone() {
        sendRequest(.sourceCatalogRequest) { [weak self] response in
            guard case .sourceCatalog(let catalog) = response, let self else {
                self?.deliverCredentialSources([])
                return
            }
            let sourceIDs = catalog.sources.map(\.sourceID)
            guard sourceIDs.allSatisfy({ !$0.isEmpty }), Set(sourceIDs).count == sourceIDs.count
            else {
                self.deliverCredentialSources([])
                return
            }
            self.deliverCredentialSources(catalog.sources)
        } onError: { [weak self] error in
            print("[WatchSessionManager] Source catalog request failed: \(error)")
            self?.deliverCredentialSources([])
        }
    }

    public func requestCredentialsFromPhone(sourceID: BookSourceID) {
        sendRequest(
            .credentialRequest(WatchCredentialRequest(sourceID: sourceID))
        ) { [weak self] response in
            guard case .credentialReply(let credentials) = response,
                credentials.sourceID == sourceID
            else {
                print("[WatchSessionManager] Invalid credential reply")
                return
            }
            let callback = self?.onCredentialsReceived
            Task { @MainActor in callback?(credentials) }
        } onError: { error in
            print("[WatchSessionManager] Credential request failed: \(error)")
        }
    }

    private func deliverCredentialSources(_ sources: [WatchCredentialSourceInfo]) {
        let callback = onCredentialSourcesReceived
        Task { @MainActor in callback?(sources) }
    }

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let envelope = file.metadata,
            let message = try? WatchProtocolMessage.decode(from: envelope),
            case .chunkTransfer(let payload) = message,
            validIncomingChunk(payload)
        else {
            print("[WatchSessionManager] Rejected non-v2 or invalid file transfer")
            return
        }

        let quarantineDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-incoming", isDirectory: true)
        let quarantinedURL = quarantineDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true,
            )
            try FileManager.default.moveItem(at: file.fileURL, to: quarantinedURL)
        } catch {
            print("[WatchSessionManager] Failed to retain received chunk: \(error)")
            return
        }

        Task {
            await processReceivedChunk(at: quarantinedURL, payload: payload)
        }
    }

    private func validIncomingChunk(_ payload: WatchChunkTransferPayload) -> Bool {
        payload.bookMetadata.id == payload.bookID
            && payload.totalChunks > 0
            && payload.chunkIndex >= 0
            && payload.chunkIndex < payload.totalChunks
            && payload.totalFileSize >= 0
            && !payload.fileExtension.isEmpty
    }

    private func processReceivedChunk(
        at quarantinedURL: URL,
        payload: WatchChunkTransferPayload,
    ) async {
        let sourceIDs = Set(
            await BookServiceActor.shared.bookSources
                .filter { $0.kind == .storyteller }
                .map(\.id)
        )
        guard sourceIDs.contains(payload.bookID.sourceID), validIncomingChunk(payload)
        else {
            try? FileManager.default.removeItem(at: quarantinedURL)
            return
        }

        let result = WatchStorageManager.shared.receiveChunk(
            from: quarantinedURL,
            payload: payload,
        )
        guard result.accepted else {
            try? FileManager.default.removeItem(at: quarantinedURL)
            return
        }

        onTransferProgress?(
            payload.title,
            payload.chunkIndex + 1,
            payload.totalChunks,
        )

        guard result.isComplete, let manifest = result.manifest else { return }
        onTransferComplete?(manifest.bookID, manifest.title)

        let success = await importTransferredBook(manifest)
        await MainActor.run { onImportComplete?(success) }
        guard success else { return }
        notifyPhoneTransferComplete(transferID: manifest.transferID)
    }

    private func importTransferredBook(_ manifest: WatchTransferManifest) async -> Bool {
        let sourceIDs = Set(
            await BookServiceActor.shared.bookSources
                .filter { $0.kind == .storyteller }
                .map(\.id)
        )
        guard sourceIDs.contains(manifest.bookID.sourceID),
            manifest.bookMetadata.id == manifest.bookID,
            let tempURL = WatchStorageManager.shared.assembleChunksToTempFile(manifest: manifest)
        else { return false }

        do {
            try await mergeBookMetadataIntoLibrary(manifest.bookMetadata)
            try await BookServiceActor.shared.importDownloadedFileToCache(
                from: tempURL,
                metadata: manifest.bookMetadata,
                category: manifest.category,
                filename: "book.\(manifest.fileExtension)",
            )
            refreshCachedBooks()
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            print("[WatchSessionManager] Failed to import transfer: \(error)")
            return false
        }
    }

    private func mergeBookMetadataIntoLibrary(_ book: BookMetadata) async throws {
        var sourceBooks = await BookServiceActor.shared
            .librarySnapshot(policy: .cachedOnly).books
            .filter { $0.sourceID == book.sourceID }

        if let index = sourceBooks.firstIndex(where: { $0.id == book.id }) {
            if isNewer(book, than: sourceBooks[index]) {
                sourceBooks[index] = book
            }
        } else {
            sourceBooks.append(book)
        }

        try await BookServiceActor.shared.updateLibraryCacheMetadata(
            sourceBooks,
            replacingSourceID: book.sourceID,
        )
    }

    private func isNewer(_ incoming: BookMetadata, than current: BookMetadata) -> Bool {
        let incomingPositionTimestamp = incoming.position?.timestamp ?? 0
        let currentPositionTimestamp = current.position?.timestamp ?? 0
        if incomingPositionTimestamp != 0 || currentPositionTimestamp != 0 {
            return incomingPositionTimestamp > currentPositionTimestamp
        }
        guard let incomingUpdatedAt = incoming.updatedAt else { return false }
        guard let currentUpdatedAt = current.updatedAt else { return true }
        return incomingUpdatedAt > currentUpdatedAt
    }

    public func requestLibraryMetadataFromPhone() async -> Bool {
        guard canSendToPhone else { return false }

        return await withCheckedContinuation { continuation in
            sendRequest(.libraryMetadataRequest) { [weak self] response in
                guard case .libraryMetadataResponse(let metadata) = response,
                    let self
                else {
                    continuation.resume(returning: false)
                    return
                }
                Task {
                    let result = await self.mergePhoneMetadata(metadata.books)
                    continuation.resume(returning: result)
                }
            } onError: { error in
                print("[WatchSessionManager] Library metadata request failed: \(error)")
                continuation.resume(returning: false)
            }
        }
    }

    private func mergePhoneMetadata(_ phoneBooks: [BookMetadata]) async -> Bool {
        let configured = Set(
            await BookServiceActor.shared.bookSources
                .filter { $0.kind == .storyteller }
                .map(\.id)
        )
        guard phoneBooks.allSatisfy({ configured.contains($0.sourceID) }) else {
            print("[WatchSessionManager] Rejected metadata for an unknown source")
            return false
        }

        let cached = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly).books
        do {
            for (sourceID, incomingBooks) in Dictionary(grouping: phoneBooks, by: \.sourceID) {
                var sourceBooks = cached.filter { $0.sourceID == sourceID }
                for incoming in incomingBooks {
                    if let index = sourceBooks.firstIndex(where: { $0.id == incoming.id }) {
                        if isNewer(incoming, than: sourceBooks[index]) {
                            sourceBooks[index] = incoming
                        }
                    } else {
                        sourceBooks.append(incoming)
                    }
                }
                try await BookServiceActor.shared.updateLibraryCacheMetadata(
                    sourceBooks,
                    replacingSourceID: sourceID,
                )
            }
            refreshCachedBooks()
            return true
        } catch {
            print("[WatchSessionManager] Failed to merge phone metadata: \(error)")
            return false
        }
    }

    public func relayPendingProgress() async {
        guard let session, canSendToPhone else { return }
        let advertisedSources = phoneSourceIDs
        let outstanding = session.outstandingUserInfoTransfers
        let pending = await ProgressSyncActor.shared.getPendingProgressSyncs()
            .filter { !$0.syncedToStoryteller }

        for item in pending where advertisedSources.contains(item.bookID.sourceID) {
            var alreadyQueued = false
            for transfer in outstanding {
                guard let message = try? WatchProtocolMessage.decode(from: transfer.userInfo),
                    case .progress(let queued) = message,
                    queued.bookID == item.bookID
                else { continue }

                if queued.timestamp >= item.timestamp {
                    alreadyQueued = true
                } else {
                    transfer.cancel()
                }
            }
            guard !alreadyQueued else { continue }

            do {
                let envelope = try WatchProtocolMessage.progress(
                    WatchProgressPayload(
                        bookID: item.bookID,
                        locator: item.locator,
                        timestamp: item.timestamp,
                    )
                ).encode()
                session.transferUserInfo(envelope)
            } catch {
                print("[WatchSessionManager] Failed to queue progress: \(error)")
            }
        }
    }

    public func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?,
    ) {
        guard let error else { return }
        let kind = try? WatchProtocolMessage.decode(from: userInfoTransfer.userInfo).kind
        print("[WatchSessionManager] \(kind?.rawValue ?? "invalid") transfer failed: \(error)")
    }

    private func notifyPhoneTransferComplete(transferID: UUID) {
        guard let session, session.activationState == .activated else { return }
        do {
            session.transferUserInfo(
                try WatchProtocolMessage.transferComplete(
                    WatchTransferReference(transferID: transferID)
                ).encode()
            )
        } catch {
            print("[WatchSessionManager] Failed to report completed transfer: \(error)")
        }
    }

    public func requestPlaybackState() {
        sendRequest(.playbackStateRequest) { [weak self] response in
            switch response {
                case .playbackState(let state): self?.onPlaybackStateReceived?(state)
                case .noPlaybackState: self?.onPlaybackStateReceived?(nil)
                default: self?.onPlaybackStateReceived?(nil)
            }
        } onError: { [weak self] error in
            print("[WatchSessionManager] Playback state request failed: \(error)")
            self?.onPlaybackStateReceived?(nil)
        }
    }

    public func sendPlaybackCommand(_ command: RemotePlaybackCommand) {
        send(.playbackCommand(command))
    }

    private var canSendToPhone: Bool {
        guard let session,
            session.activationState == .activated,
            protocolContext(from: session.receivedApplicationContext) != nil
        else { return false }
        return true
    }

    private var phoneSourceIDs: Set<BookSourceID> {
        guard let session,
            let context = protocolContext(from: session.receivedApplicationContext)
        else { return [] }
        return Set(context.sourceIDs)
    }

    private func protocolContext(from envelope: [String: Any]) -> WatchProtocolContext? {
        guard let message = try? WatchProtocolMessage.decode(from: envelope),
            case .context(let context) = message
        else { return nil }
        return context
    }

    private func send(_ message: WatchProtocolMessage) {
        guard let session, session.isReachable, canSendToPhone else { return }
        do {
            session.sendMessage(
                try message.encode(),
                replyHandler: nil,
                errorHandler: { error in
                    print("[WatchSessionManager] Send failed: \(error)")
                },
            )
        } catch {
            print("[WatchSessionManager] Failed to encode message: \(error)")
        }
    }

    private func sendRequest(
        _ message: WatchProtocolMessage,
        onReply: @escaping @Sendable (WatchProtocolMessage) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
    ) {
        guard let session, session.isReachable, canSendToPhone else {
            onError(WatchSessionError.phoneUnavailable)
            return
        }
        do {
            session.sendMessage(
                try message.encode(),
                replyHandler: { envelope in
                    do {
                        onReply(try WatchProtocolMessage.decode(from: envelope))
                    } catch {
                        onError(error)
                    }
                },
                errorHandler: onError,
            )
        } catch {
            onError(error)
        }
    }

    private func reply(
        _ message: WatchProtocolMessage,
        to replyHandler: (([String: Any]) -> Void)?,
    ) {
        guard let replyHandler, let envelope = try? message.encode() else { return }
        replyHandler(envelope)
    }
}

private struct SendableWatchReplyHandler: @unchecked Sendable {
    let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func reply(_ response: [String: Any]?) {
        guard let response else { return }
        handler(response)
    }
}

private enum WatchSessionError: Error {
    case phoneUnavailable
}
#endif
