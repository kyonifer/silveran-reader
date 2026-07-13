import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

#if os(iOS)
import UIKit
#endif

public enum WatchTransferState: Sendable, Codable {
    case queued
    case transferring(progress: Double)
    case completed
    case failed(message: String)
}

public struct WatchTransferItem: Sendable, Identifiable, Codable {
    public let id: UUID
    public let bookID: BookID
    public let bookTitle: String
    public let category: LocalMediaCategory
    public let state: WatchTransferState
    public let totalBytes: Int64
    public let transferredBytes: Int64
    public let startedAt: Date
    public var completedAt: Date?

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
}

public enum WatchTransferEvent: Sendable {
    case stateChanged(item: WatchTransferItem)
    case transfersUpdated(items: [WatchTransferItem])
    case watchBooksUpdated(books: [WatchBookInfo])
    case watchReachabilityChanged(isReachable: Bool)
}

#if canImport(WatchConnectivity)

private let watchChunkCount = 100

@globalActor
public actor AppleWatchActor: NSObject {
    public static let shared = AppleWatchActor()

    private var session: WCSession?
    private var pendingTransfers: [UUID: WatchTransferItem] = [:]
    private var completedTransfers: [UUID: WatchTransferItem] = [:]
    private var watchBooks: [WatchBookInfo] = []
    private var chunksCompleted: [UUID: Int] = [:]
    private var chunksExpected: [UUID: Int] = [:]
    private var observers: [UUID: @Sendable @MainActor (WatchTransferEvent) -> Void] = [:]
    private var smilObserverID: UUID?

    public override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else {
            debugLog("[AppleWatchActor] WatchConnectivity not supported on this device")
            return
        }

        let wcSession = WCSession.default
        wcSession.delegate = self
        session = wcSession
        wcSession.activate()
        debugLog("[AppleWatchActor] WCSession activation requested")
    }

    public func addObserver(_ callback: @escaping @Sendable @MainActor (WatchTransferEvent) -> Void)
        -> UUID
    {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers(_ event: WatchTransferEvent) {
        let callbacks = observers.values
        Task { @MainActor in
            for callback in callbacks {
                callback(event)
            }
        }
    }

    public func isWatchPaired() -> Bool {
        #if os(iOS)
        session?.isPaired == true
        #else
        true
        #endif
    }

    public func isWatchReachable() -> Bool {
        session?.isReachable == true && connectedWatchContext() != nil
    }

    public func getPendingTransfers() -> [WatchTransferItem] {
        pendingTransfers.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func getCompletedTransfers() -> [WatchTransferItem] {
        completedTransfers.values.sorted {
            ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
        }
    }

    public func getWatchBooks() -> [WatchBookInfo] {
        watchBooks
    }

    public func queueTransfer(
        book: BookMetadata,
        category: LocalMediaCategory,
        sourceURL: URL,
    ) async throws {
        guard let session, session.activationState == .activated else {
            throw WatchTransferError.sessionNotActive
        }
        #if os(iOS)
        guard session.isPaired else {
            throw WatchTransferError.watchNotPaired
        }
        #endif
        guard let context = connectedWatchContext() else {
            throw WatchTransferError.watchUpdateRequired
        }
        guard context.sourceIDs.contains(book.id.sourceID) else {
            throw WatchTransferError.sourceNotAvailable
        }
        reconcileOutstandingFileTransfers()
        if pendingTransfers.values.contains(where: {
            $0.bookID == book.id && $0.category == category
        }) {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            throw WatchTransferError.transferFailed("File is empty")
        }

        let transferID = UUID()
        var item = WatchTransferItem(
            id: transferID,
            bookID: book.id,
            bookTitle: book.title,
            category: category,
            state: .queued,
            totalBytes: fileSize,
            transferredBytes: 0,
            startedAt: Date(),
        )
        pendingTransfers[transferID] = item
        chunksCompleted[transferID] = 0
        notifyObservers(.stateChanged(item: item))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))

        item = updateItem(item, state: .transferring(progress: 0))
        do {
            try sendFileInChunks(
                sourceURL: sourceURL,
                book: book,
                category: category,
                transferID: transferID,
            )
        } catch {
            cancelOutstandingFiles(transferID: transferID)
            queueTransferCancellation(transferID: transferID)
            chunksCompleted.removeValue(forKey: transferID)
            chunksExpected.removeValue(forKey: transferID)
            removeTransferFiles(transferID: transferID)
            _ = updateItem(item, state: .failed(message: error.localizedDescription))
            throw error
        }
    }

    private func updateItem(
        _ item: WatchTransferItem,
        state: WatchTransferState,
        transferredBytes: Int64? = nil,
        completedAt: Date? = nil,
    ) -> WatchTransferItem {
        let updated = WatchTransferItem(
            id: item.id,
            bookID: item.bookID,
            bookTitle: item.bookTitle,
            category: item.category,
            state: state,
            totalBytes: item.totalBytes,
            transferredBytes: transferredBytes ?? item.transferredBytes,
            startedAt: item.startedAt,
            completedAt: completedAt ?? item.completedAt,
        )
        pendingTransfers[item.id] = updated
        notifyObservers(.stateChanged(item: updated))
        return updated
    }

    private func sendFileInChunks(
        sourceURL: URL,
        book: BookMetadata,
        category: LocalMediaCategory,
        transferID: UUID,
    ) throws {
        guard let session, session.activationState == .activated else {
            throw WatchTransferError.sessionNotActive
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WatchTransferError.fileNotFound(sourceURL.path)
        }

        let totalSize =
            try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64 ?? 0
        guard totalSize > 0 else {
            throw WatchTransferError.transferFailed("File is empty")
        }

        let chunkSize = (totalSize + Int64(watchChunkCount) - 1) / Int64(watchChunkCount)
        let actualChunkCount = Int((totalSize + chunkSize - 1) / chunkSize)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch_chunks_\(transferID.uuidString)",
            isDirectory: true,
        )
        try? FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
        )

        let fileExtension = sourceURL.pathExtension
        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fileHandle.close() }
        chunksExpected[transferID] = actualChunkCount

        for chunkIndex in 0..<actualChunkCount {
            guard connectedWatchContext()?.sourceIDs.contains(book.id.sourceID) == true else {
                throw WatchTransferError.sourceNotAvailable
            }

            let startOffset = Int64(chunkIndex) * chunkSize
            try fileHandle.seek(toOffset: UInt64(startOffset))
            let bytesToRead = min(Int(chunkSize), Int(totalSize - startOffset))
            guard let chunkData = try fileHandle.read(upToCount: bytesToRead), !chunkData.isEmpty
            else {
                throw WatchTransferError.transferFailed("Could not read transfer chunk")
            }

            let chunkURL = tempDirectory.appendingPathComponent(
                "chunk_\(String(format: "%03d", chunkIndex)).\(fileExtension)"
            )
            try chunkData.write(to: chunkURL)

            let payload = WatchChunkTransferPayload(
                transferID: transferID,
                bookID: book.id,
                category: category,
                chunkIndex: chunkIndex,
                totalChunks: actualChunkCount,
                totalFileSize: totalSize,
                fileExtension: fileExtension,
                title: book.title,
                authors: book.authors?.compactMap(\.name) ?? [],
                bookMetadata: book,
            )
            let metadata = try WatchProtocolMessage.chunkTransfer(payload).encode()
            let transfer = session.transferFile(chunkURL, metadata: metadata)
            debugLog(
                "[AppleWatchActor] Queued chunk \(chunkIndex + 1)/\(actualChunkCount), isTransferring: \(transfer.isTransferring)"
            )
        }
    }

    public func cancelTransfer(transferID: UUID) {
        cancelTransfer(transferID: transferID, notifyWatch: true)
    }

    private func cancelTransfer(transferID: UUID, notifyWatch: Bool) {
        guard let item = pendingTransfers[transferID] else { return }

        cancelOutstandingFiles(transferID: transferID)
        if notifyWatch {
            queueTransferCancellation(transferID: transferID)
        }

        let cancelled = WatchTransferItem(
            id: item.id,
            bookID: item.bookID,
            bookTitle: item.bookTitle,
            category: item.category,
            state: .failed(message: "Cancelled"),
            totalBytes: item.totalBytes,
            transferredBytes: item.transferredBytes,
            startedAt: item.startedAt,
            completedAt: Date(),
        )
        pendingTransfers.removeValue(forKey: transferID)
        chunksCompleted.removeValue(forKey: transferID)
        chunksExpected.removeValue(forKey: transferID)
        removeTransferFiles(transferID: transferID)
        notifyObservers(.stateChanged(item: cancelled))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))
    }

    public func removeCompletedTransfer(transferID: UUID) {
        completedTransfers.removeValue(forKey: transferID)
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))
    }

    public func requestWatchLibrary() {
        guard let session,
            session.activationState == .activated,
            session.isReachable,
            connectedWatchContext() != nil,
            let request = try? WatchProtocolMessage.watchLibraryRequest.encode()
        else { return }

        session.sendMessage(
            request,
            replyHandler: { [weak self] response in
                guard let message = try? WatchProtocolMessage.decode(from: response) else { return }
                Task { await self?.handleWatchLibrary(message) }
            },
            errorHandler: { error in
                debugLog("[AppleWatchActor] Failed to request library: \(error)")
            },
        )
    }

    public func deleteBookFromWatch(bookID: BookID, category: LocalMediaCategory) {
        guard session?.activationState == .activated,
            session?.isReachable == true,
            connectedWatchContext()?.sourceIDs.contains(bookID.sourceID) == true
        else { return }

        let message = WatchProtocolMessage.deleteBook(
            WatchDeleteBookPayload(bookID: bookID, category: category)
        )
        send(
            message,
            replyHandler: { [weak self] response in
                guard case .acknowledgement = try? WatchProtocolMessage.decode(from: response)
                else { return }
                Task { await self?.requestWatchLibrary() }
            },
        )
    }

    private func handleWatchLibrary(_ message: WatchProtocolMessage) {
        guard case .watchLibrary(let library) = message,
            let context = connectedWatchContext(),
            library.books.allSatisfy({ context.sourceIDs.contains($0.bookID.sourceID) })
        else { return }

        watchBooks = library.books
        notifyObservers(.watchBooksUpdated(books: library.books))
    }

    private func handleTransferComplete(transferID: UUID) {
        guard let current = pendingTransfers.removeValue(forKey: transferID) else { return }

        chunksCompleted.removeValue(forKey: transferID)
        chunksExpected.removeValue(forKey: transferID)
        let completed = WatchTransferItem(
            id: current.id,
            bookID: current.bookID,
            bookTitle: current.bookTitle,
            category: current.category,
            state: .completed,
            totalBytes: current.totalBytes,
            transferredBytes: current.totalBytes,
            startedAt: current.startedAt,
            completedAt: Date(),
        )
        completedTransfers[transferID] = completed
        removeTransferFiles(transferID: transferID)
        notifyObservers(.stateChanged(item: completed))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))
        requestWatchLibrary()
    }

    private func handleChunkSent(transferID: UUID) {
        guard let item = pendingTransfers[transferID],
            let expected = chunksExpected[transferID]
        else { return }

        let completed = (chunksCompleted[transferID] ?? 0) + 1
        chunksCompleted[transferID] = completed
        let progress = min(Double(completed) / Double(expected), 1)
        _ = updateItem(
            item,
            state: .transferring(progress: progress),
            transferredBytes: Int64(Double(item.totalBytes) * progress),
        )
    }

    private func handleFileTransferResult(transferID: UUID, errorMessage: String?) {
        if let errorMessage {
            cancelOutstandingFiles(transferID: transferID)
            queueTransferCancellation(transferID: transferID)
            chunksCompleted.removeValue(forKey: transferID)
            chunksExpected.removeValue(forKey: transferID)
            removeTransferFiles(transferID: transferID)
            guard let item = pendingTransfers[transferID] else { return }
            _ = updateItem(item, state: .failed(message: errorMessage))
        } else {
            handleChunkSent(transferID: transferID)
        }
    }

    private func cancelOutstandingFiles(transferID: UUID) {
        guard let session else { return }
        for transfer in session.outstandingFileTransfers {
            guard let metadata = transfer.file.metadata,
                case .chunkTransfer(let payload) = try? WatchProtocolMessage.decode(from: metadata),
                payload.transferID == transferID
            else { continue }
            transfer.cancel()
        }
    }

    private func reconcileOutstandingFileTransfers() {
        guard let session else { return }
        let activeTransferIDs = Set(pendingTransfers.keys)
        var orphanedTransferIDs: Set<UUID> = []

        for transfer in session.outstandingFileTransfers {
            guard let metadata = transfer.file.metadata,
                case .chunkTransfer(let payload) = try? WatchProtocolMessage.decode(from: metadata)
            else {
                transfer.cancel()
                continue
            }
            guard !activeTransferIDs.contains(payload.transferID) else { continue }
            transfer.cancel()
            orphanedTransferIDs.insert(payload.transferID)
        }

        for transferID in orphanedTransferIDs {
            chunksCompleted.removeValue(forKey: transferID)
            chunksExpected.removeValue(forKey: transferID)
            removeTransferFiles(transferID: transferID)
            queueTransferCancellation(transferID: transferID)
        }
    }

    private func queueTransferCancellation(transferID: UUID) {
        guard let session else { return }
        let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
            guard case .cancelTransfer(let reference) = try? WatchProtocolMessage.decode(
                from: transfer.userInfo
            ) else { return false }
            return reference.transferID == transferID
        }
        guard !alreadyQueued,
            let envelope = try? WatchProtocolMessage.cancelTransfer(
                WatchTransferReference(transferID: transferID)
            ).encode()
        else { return }
        session.transferUserInfo(envelope)
    }

    private func removeTransferFiles(transferID: UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch_chunks_\(transferID.uuidString)",
            isDirectory: true,
        )
        try? FileManager.default.removeItem(at: directory)
    }

    private func connectedWatchContext() -> WatchProtocolContext? {
        guard let session,
            case .context(let context) = try? WatchProtocolMessage.decode(
                from: session.receivedApplicationContext
            )
        else { return nil }
        return context
    }

    private func publishApplicationContext() async {
        guard let session, session.activationState == .activated else { return }
        let sourceIDs = await BookServiceActor.shared.bookSources
            .filter { $0.kind == .storyteller }
            .map(\.id)
            .sorted()
        do {
            try session.updateApplicationContext(
                WatchProtocolMessage.context(
                    WatchProtocolContext(sourceIDs: sourceIDs)
                ).encode()
            )
        } catch {
            debugLog("[AppleWatchActor] Failed to publish application context: \(error)")
        }
    }

    private func send(
        _ message: WatchProtocolMessage,
        replyHandler: (([String: Any]) -> Void)? = nil,
    ) {
        guard let session, let encoded = try? message.encode() else { return }
        session.sendMessage(
            encoded,
            replyHandler: replyHandler,
            errorHandler: { error in
                debugLog("[AppleWatchActor] Failed to send \(message.kind.rawValue): \(error)")
            },
        )
    }

    // MARK: - Remote Playback Control

    public func startObservingSMILPlayer() {
        guard smilObserverID == nil else { return }
        let observerID = UUID()
        smilObserverID = observerID
        Task {
            await SMILPlayerActor.shared.addStateObserver(id: observerID) { [weak self] _ in
                Task { await self?.sendPlaybackStateToWatch() }
            }
        }
    }

    public func stopObservingSMILPlayer() {
        guard let observerID = smilObserverID else { return }
        smilObserverID = nil
        Task {
            await SMILPlayerActor.shared.removeStateObserver(id: observerID)
        }
    }

    public func sendPlaybackStateToWatch() async {
        guard session?.isReachable == true, connectedWatchContext() != nil else { return }
        guard let state = await buildRemotePlaybackState() else {
            send(.noPlaybackState)
            return
        }
        guard connectedWatchContext()?.sourceIDs.contains(state.bookID.sourceID) == true else {
            return
        }
        send(.playbackState(state))
    }

    private func buildRemotePlaybackState() async -> RemotePlaybackState? {
        guard let smilState = await SMILPlayerActor.shared.getCurrentState(),
            let bookID = smilState.bookID
        else { return nil }

        let chapters = await SMILPlayerActor.shared.getBookStructure()
            .filter { !$0.mediaOverlay.isEmpty }
            .enumerated()
            .map { index, section in
                RemoteChapter(
                    index: index,
                    title: section.label ?? "Chapter \(index + 1)",
                    sectionIndex: section.index,
                )
            }
        let currentChapterIndex =
            chapters.firstIndex { $0.sectionIndex == smilState.currentSectionIndex } ?? 0

        return RemotePlaybackState(
            bookTitle: await SMILPlayerActor.shared.getLoadedBookTitle() ?? "Unknown",
            bookID: bookID,
            chapterTitle: smilState.chapterLabel ?? "Chapter \(currentChapterIndex + 1)",
            currentChapterIndex: currentChapterIndex,
            chapters: chapters,
            isPlaying: smilState.isPlaying,
            chapterElapsed: smilState.chapterElapsed,
            chapterDuration: smilState.chapterTotal,
            bookElapsed: smilState.bookElapsed,
            bookDuration: smilState.bookTotal,
            playbackRate: smilState.playbackRate,
            volume: smilState.volume,
        )
    }

    private func handlePlaybackCommand(_ command: RemotePlaybackCommand) async {
        do {
            switch command {
                case .togglePlayPause:
                    try await SMILPlayerActor.shared.togglePlayPause()
                case .skipForward:
                    await SMILPlayerActor.shared.skipForward(seconds: 30)
                case .skipBackward:
                    await SMILPlayerActor.shared.skipBackward(seconds: 30)
                case .seekToChapter(let sectionIndex):
                    try await SMILPlayerActor.shared.seekToEntry(
                        sectionIndex: sectionIndex,
                        entryIndex: 0,
                    )
                case .setPlaybackRate(let rate):
                    await SMILPlayerActor.shared.setPlaybackRate(rate)
                case .setVolume(let volume):
                    await SMILPlayerActor.shared.setVolume(volume)
            }
        } catch {
            debugLog("[AppleWatchActor] Playback command failed: \(error)")
        }
    }

    private func handleIncomingMessage(_ message: WatchProtocolMessage) async {
        switch message {
            case .progress(let payload):
                await handleRelayedProgress(payload)
            case .transferComplete(let reference):
                guard pendingTransfers[reference.transferID] != nil else { return }
                handleTransferComplete(transferID: reference.transferID)
            case .cancelTransfer(let reference):
                guard pendingTransfers[reference.transferID] != nil else { return }
                cancelTransfer(transferID: reference.transferID, notifyWatch: false)
            case .watchLibrary:
                handleWatchLibrary(message)
            case .playbackCommand(let command):
                await handlePlaybackCommand(command)
            case .playbackStateRequest:
                await sendPlaybackStateToWatch()
            default:
                break
        }
    }

    private func handleRequest(
        _ message: WatchProtocolMessage,
        replyHandler: SendableReplyHandler,
    ) async {
        switch message {
            case .ping:
                replyHandler.reply(.pong)
            case .playbackStateRequest:
                guard let context = connectedWatchContext(),
                    let state = await buildRemotePlaybackState(),
                    context.sourceIDs.contains(state.bookID.sourceID)
                else {
                    replyHandler.reply(.noPlaybackState)
                    return
                }
                replyHandler.reply(.playbackState(state))
            case .playbackCommand(let command):
                await handlePlaybackCommand(command)
                replyHandler.reply(.acknowledgement)
            case .sourceCatalogRequest:
                await publishApplicationContext()
                replyHandler.reply(.sourceCatalog(await sourceCatalog()))
            case .credentialRequest(let request):
                guard let reply = await credentialReply(sourceID: request.sourceID) else {
                    replyHandler.reply(
                        .failure(WatchFailure(message: "No credentials configured"))
                    )
                    return
                }
                replyHandler.reply(.credentialReply(reply))
            case .libraryMetadataRequest:
                guard let context = connectedWatchContext() else {
                    replyHandler.reply(
                        .failure(WatchFailure(message: "Watch context unavailable"))
                    )
                    return
                }
                let allowedSourceIDs = Set(context.sourceIDs)
                let books = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly).books
                    .filter { allowedSourceIDs.contains($0.id.sourceID) }
                replyHandler.reply(
                    .libraryMetadataResponse(WatchLibraryMetadataResponse(books: books))
                )
            default:
                replyHandler.reply(.failure(WatchFailure(message: "Unhandled request")))
        }
    }

    private func sourceCatalog() async -> WatchSourceCatalog {
        let sourceRecords = await BookServiceActor.shared.bookSources
            .filter { $0.kind == .storyteller }
        var sources: [WatchCredentialSourceInfo] = []
        for record in sourceRecords {
            guard let credentials = try? await AuthenticationActor.shared.loadCredentials(
                sourceID: record.id
            ) else { continue }
            sources.append(
                WatchCredentialSourceInfo(
                    sourceID: record.id,
                    name: record.name,
                    url: credentials.url,
                    username: credentials.username,
                )
            )
        }
        return WatchSourceCatalog(
            sources: sources.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                return comparison == .orderedSame
                    ? $0.sourceID < $1.sourceID : comparison == .orderedAscending
            }
        )
    }

    private func credentialReply(sourceID: BookSourceID) async -> WatchCredentialReply? {
        guard let source = await BookServiceActor.shared.bookSources.first(where: {
            $0.id == sourceID && $0.kind == .storyteller
        }),
            let credentials = try? await AuthenticationActor.shared.loadCredentials(
                sourceID: sourceID
            )
        else { return nil }

        return WatchCredentialReply(
            sourceID: sourceID,
            name: source.name,
            url: credentials.url,
            username: credentials.username,
            password: credentials.password,
        )
    }

    private func handleRelayedProgress(_ payload: WatchProgressPayload) async {
        #if os(iOS)
        let backgroundTask = await beginRelayBackgroundTask()
        #endif

        let sourceExists = await BookServiceActor.shared.bookSources.contains {
            $0.id == payload.bookID.sourceID && $0.kind == .storyteller
        }
        if sourceExists {
            _ = await ProgressSyncActor.shared.syncProgress(
                bookID: payload.bookID,
                locator: payload.locator,
                timestamp: payload.timestamp,
                reason: .relayedFromWatch,
                sourceIdentifier: "Watch Relay",
            )
            #if os(iOS)
            await ProgressUploadManager.shared.enqueuePendingUploads()
            #endif
        }

        #if os(iOS)
        await endRelayBackgroundTask(backgroundTask)
        #endif
    }

    #if os(iOS)
    private func beginRelayBackgroundTask() async -> UIBackgroundTaskIdentifier {
        await MainActor.run {
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "WatchProgressRelay") {
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }
            return taskID
        }
    }

    private func endRelayBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) async {
        await MainActor.run {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
    }
    #endif

    private func handleActivationComplete(
        activationState: WCSessionActivationState,
        error: Error?,
    ) async {
        if let error {
            debugLog("[AppleWatchActor] Activation failed: \(error)")
            return
        }
        guard activationState == .activated else { return }
        reconcileOutstandingFileTransfers()
        await publishApplicationContext()
        guard connectedWatchContext() != nil else {
            stopObservingSMILPlayer()
            return
        }
        requestWatchLibrary()
        if session?.isReachable == true {
            startObservingSMILPlayer()
        }
    }

    private func handleReachabilityChange(isReachable: Bool) async {
        await publishApplicationContext()
        let isCompatibleAndReachable = isReachable && connectedWatchContext() != nil
        notifyObservers(.watchReachabilityChanged(isReachable: isCompatibleAndReachable))
        if isCompatibleAndReachable {
            requestWatchLibrary()
            startObservingSMILPlayer()
        } else {
            stopObservingSMILPlayer()
        }
    }

    private func handleApplicationContext(_: WatchProtocolContext) async {
        await publishApplicationContext()
        let isCompatibleAndReachable = session?.isReachable == true
        notifyObservers(.watchReachabilityChanged(isReachable: isCompatibleAndReachable))
        guard isCompatibleAndReachable else { return }
        requestWatchLibrary()
        startObservingSMILPlayer()
    }
}

extension AppleWatchActor: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?,
    ) {
        Task {
            await self.handleActivationComplete(
                activationState: activationState,
                error: error,
            )
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        Task { await self.activate() }
    }
    #endif

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { await self.handleReachabilityChange(isReachable: isReachable) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = try? WatchProtocolMessage.decode(from: message) else { return }
        Task { await self.handleIncomingMessage(decoded) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void,
    ) {
        let sendableReply = SendableReplyHandler(replyHandler)
        guard let decoded = try? WatchProtocolMessage.decode(from: message) else {
            sendableReply.reply(
                .failure(WatchFailure(message: "Incompatible watch protocol"))
            )
            return
        }
        Task { await self.handleRequest(decoded, replyHandler: sendableReply) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:],
    ) {
        guard let decoded = try? WatchProtocolMessage.decode(from: userInfo) else { return }
        Task { await self.handleIncomingMessage(decoded) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any],
    ) {
        guard case .context(let context) = try? WatchProtocolMessage.decode(
            from: applicationContext
        ) else { return }
        Task { await self.handleApplicationContext(context) }
    }

    nonisolated public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?,
    ) {
        guard let metadata = fileTransfer.file.metadata,
            case .chunkTransfer(let payload) = try? WatchProtocolMessage.decode(from: metadata),
            payload.bookMetadata.id == payload.bookID
        else { return }
        let errorMessage = error?.localizedDescription
        Task {
            await self.handleFileTransferResult(
                transferID: payload.transferID,
                errorMessage: errorMessage,
            )
        }
    }
}

struct SendableReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func reply(_ message: WatchProtocolMessage) {
        guard let encoded = try? message.encode() else { return }
        handler(encoded)
    }
}

#else

@globalActor
public actor AppleWatchActor {
    public static let shared = AppleWatchActor()

    public init() {}

    public func activate() {
        debugLog("[AppleWatchActor] WatchConnectivity not available on this platform")
    }

    public func addObserver(_ callback: @escaping @Sendable @MainActor (WatchTransferEvent) -> Void)
        -> UUID
    {
        UUID()
    }

    public func removeObserver(_ id: UUID) {}
    public func isWatchPaired() -> Bool { false }
    public func isWatchReachable() -> Bool { false }
    public func getPendingTransfers() -> [WatchTransferItem] { [] }
    public func getCompletedTransfers() -> [WatchTransferItem] { [] }
    public func getWatchBooks() -> [WatchBookInfo] { [] }

    public func queueTransfer(book: BookMetadata, category: LocalMediaCategory, sourceURL: URL)
        async throws
    {
        throw WatchTransferError.notSupported
    }

    public func cancelTransfer(transferID: UUID) {}
    public func removeCompletedTransfer(transferID: UUID) {}
    public func requestWatchLibrary() {}
    public func deleteBookFromWatch(bookID: BookID, category: LocalMediaCategory) {}
}

#endif

enum WatchTransferError: Error, LocalizedError {
    case sessionNotActive
    case watchNotPaired
    case watchUpdateRequired
    case sourceNotAvailable
    case transferFailed(String)
    case fileNotFound(String)
    case notSupported

    var errorDescription: String? {
        switch self {
            case .sessionNotActive:
                "Watch session is not active"
            case .watchNotPaired:
                "No Apple Watch is paired"
            case .watchUpdateRequired:
                "Update Silveran Reader on Apple Watch before sending books."
            case .sourceNotAvailable:
                "This book's source is not configured on Apple Watch."
            case .transferFailed(let reason):
                "Transfer failed: \(reason)"
            case .fileNotFound(let path):
                "File not found: \(path)"
            case .notSupported:
                "Apple Watch transfers not supported on this platform"
        }
    }
}
