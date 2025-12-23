import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public enum WatchTransferState: Sendable, Codable {
    case queued
    case transferring(progress: Double)
    case completed
    case failed(message: String)
}

public struct WatchTransferItem: Sendable, Identifiable, Codable {
    public let id: String
    public let bookUUID: String
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

public struct WatchBookInfo: Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let authorNames: [String]
    public let category: LocalMediaCategory
    public let sizeBytes: Int64

    public var authorDisplay: String {
        authorNames.joined(separator: ", ")
    }
}

public enum WatchTransferEvent: Sendable {
    case stateChanged(item: WatchTransferItem)
    case transfersUpdated(items: [WatchTransferItem])
    case watchBooksUpdated(books: [WatchBookInfo])
    case watchReachabilityChanged(isReachable: Bool)
}

#if canImport(WatchConnectivity)

private let kChunkCount = 100

@globalActor
public actor AppleWatchActor: NSObject {
    public static let shared = AppleWatchActor()

    private var session: WCSession?
    private var isActivated = false
    private var pendingTransfers: [String: WatchTransferItem] = [:]
    private var completedTransfers: [String: WatchTransferItem] = [:]
    private var watchBooks: [WatchBookInfo] = []
    private var chunksCompleted: [String: Int] = [:]
    private var chunksExpected: [String: Int] = [:]
    private var observers: [UUID: @Sendable @MainActor (WatchTransferEvent) -> Void] = [:]
    private var smilObserverId: UUID?
    private var cachedChapters: [RemoteChapter] = []

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
        wcSession.activate()
        session = wcSession
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
        guard let session else { return false }
        return session.isPaired
        #else
        return true
        #endif
    }

    public func isWatchReachable() -> Bool {
        guard let session else { return false }
        return session.isReachable
    }

    public func getPendingTransfers() -> [WatchTransferItem] {
        Array(pendingTransfers.values).sorted { $0.startedAt < $1.startedAt }
    }

    public func getCompletedTransfers() -> [WatchTransferItem] {
        Array(completedTransfers.values).sorted {
            ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt)
        }
    }

    public func getWatchBooks() -> [WatchBookInfo] {
        watchBooks
    }

    public func queueTransfer(
        book: BookMetadata,
        category: LocalMediaCategory,
        sourceURL: URL
    ) async throws {
        let transferId = "\(book.uuid)-\(category.rawValue)"

        if pendingTransfers[transferId] != nil {
            debugLog("[AppleWatchActor] Transfer already queued: \(transferId)")
            return
        }

        let fileSize =
            try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64 ?? 0

        let item = WatchTransferItem(
            id: transferId,
            bookUUID: book.uuid,
            bookTitle: book.title,
            category: category,
            state: .queued,
            totalBytes: fileSize,
            transferredBytes: 0,
            startedAt: Date()
        )

        pendingTransfers[transferId] = item
        chunksCompleted[transferId] = 0
        notifyObservers(.stateChanged(item: item))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))

        await processTransfer(
            transferId: transferId,
            book: book,
            category: category,
            sourceURL: sourceURL
        )
    }

    private func processTransfer(
        transferId: String,
        book: BookMetadata,
        category: LocalMediaCategory,
        sourceURL: URL
    ) async {
        guard var item = pendingTransfers[transferId] else { return }

        do {
            let fileSize =
                try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64
                ?? 0
            item = updateItem(item, state: .transferring(progress: 0), totalBytes: fileSize)

            try await sendFileInChunks(
                sourceURL: sourceURL,
                book: book,
                category: category,
                transferId: transferId
            )

        } catch {
            debugLog("[AppleWatchActor] Transfer failed: \(error)")
            let failedItem = updateItem(item, state: .failed(message: error.localizedDescription))
            pendingTransfers[transferId] = failedItem
            notifyObservers(.stateChanged(item: failedItem))
        }
    }

    private func updateItem(
        _ item: WatchTransferItem,
        state: WatchTransferState,
        totalBytes: Int64? = nil,
        transferredBytes: Int64? = nil
    ) -> WatchTransferItem {
        let updated = WatchTransferItem(
            id: item.id,
            bookUUID: item.bookUUID,
            bookTitle: item.bookTitle,
            category: item.category,
            state: state,
            totalBytes: totalBytes ?? item.totalBytes,
            transferredBytes: transferredBytes ?? item.transferredBytes,
            startedAt: item.startedAt,
            completedAt: item.completedAt
        )
        pendingTransfers[item.id] = updated
        notifyObservers(.stateChanged(item: updated))
        return updated
    }

    private func sendFileInChunks(
        sourceURL: URL,
        book: BookMetadata,
        category: LocalMediaCategory,
        transferId: String
    ) async throws {
        guard let session, session.activationState == .activated else {
            throw WatchTransferError.sessionNotActive
        }

        #if os(iOS)
        guard session.isPaired else {
            throw WatchTransferError.watchNotPaired
        }
        #endif

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw WatchTransferError.fileNotFound(sourceURL.path)
        }

        // Cancel any previous transfers for this same transferId
        var cancelledCount = 0
        for transfer in session.outstandingFileTransfers {
            if let tid = transfer.file.metadata?["transferId"] as? String, tid == transferId {
                transfer.cancel()
                cancelledCount += 1
            }
        }
        if cancelledCount > 0 {
            debugLog(
                "[AppleWatchActor] Cancelled \(cancelledCount) previous transfers for \(transferId)"
            )
        }

        let attrs = try fm.attributesOfItem(atPath: sourceURL.path)
        let totalSize = attrs[.size] as? Int64 ?? 0

        guard totalSize > 0 else {
            throw WatchTransferError.transferFailed("File is empty")
        }

        let chunkSize = (totalSize + Int64(kChunkCount) - 1) / Int64(kChunkCount)
        let actualChunkCount = Int((totalSize + chunkSize - 1) / chunkSize)

        debugLog(
            "[AppleWatchActor] Starting chunked transfer: \(sourceURL.lastPathComponent), size: \(totalSize) bytes, chunkSize: \(chunkSize), chunks: \(actualChunkCount)"
        )

        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "watch_chunks_\(transferId)",
            isDirectory: true
        )
        try? fm.removeItem(at: tempDir)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension

        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fileHandle.close() }

        chunksExpected[transferId] = actualChunkCount

        for chunkIndex in 0..<actualChunkCount {
            let startOffset = Int64(chunkIndex) * chunkSize

            try fileHandle.seek(toOffset: UInt64(startOffset))
            let bytesToRead = min(Int(chunkSize), Int(totalSize - startOffset))
            guard let chunkData = try fileHandle.read(upToCount: bytesToRead), !chunkData.isEmpty
            else {
                debugLog("[AppleWatchActor] Failed to read chunk \(chunkIndex)")
                continue
            }

            let chunkFileName = "chunk_\(String(format: "%03d", chunkIndex)).\(fileExtension)"
            let chunkURL = tempDir.appendingPathComponent(chunkFileName)

            try chunkData.write(to: chunkURL)

            let chunkMetadata = ChunkTransferMetadata(
                uuid: book.uuid,
                title: book.title,
                authors: book.authors?.compactMap { $0.name } ?? [],
                category: category.rawValue,
                chunkIndex: chunkIndex,
                totalChunks: actualChunkCount,
                totalFileSize: totalSize,
                fileExtension: fileExtension
            )
            let metadataData = try JSONEncoder().encode(chunkMetadata)

            let fileMetadata: [String: Any] = [
                "transferId": transferId,
                "chunkMetadata": metadataData,
            ]

            let transfer = session.transferFile(chunkURL, metadata: fileMetadata)
            debugLog(
                "[AppleWatchActor] Queued chunk \(chunkIndex + 1)/\(actualChunkCount), isTransferring: \(transfer.isTransferring)"
            )
        }

        debugLog(
            "[AppleWatchActor] Finished queueing \(actualChunkCount) chunks, outstanding: \(session.outstandingFileTransfers.count)"
        )
    }

    public func cancelTransfer(transferId: String) {
        guard let item = pendingTransfers[transferId] else { return }

        if let session {
            for transfer in session.outstandingFileTransfers {
                if let tid = transfer.file.metadata?["transferId"] as? String, tid == transferId {
                    transfer.cancel()
                }
            }

            if session.isReachable {
                let message: [String: Any] = [
                    "type": "cancelTransfer",
                    "uuid": item.bookUUID,
                    "category": item.category.rawValue,
                ]
                session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        }

        let cancelledItem = WatchTransferItem(
            id: item.id,
            bookUUID: item.bookUUID,
            bookTitle: item.bookTitle,
            category: item.category,
            state: .failed(message: "Cancelled"),
            totalBytes: item.totalBytes,
            transferredBytes: item.transferredBytes,
            startedAt: item.startedAt,
            completedAt: Date()
        )

        pendingTransfers.removeValue(forKey: transferId)
        chunksCompleted.removeValue(forKey: transferId)
        chunksExpected.removeValue(forKey: transferId)
        notifyObservers(.stateChanged(item: cancelledItem))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))
    }

    public func removeCompletedTransfer(transferId: String) {
        completedTransfers.removeValue(forKey: transferId)
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))
    }

    public func requestWatchLibrary() {
        guard let session, session.activationState == .activated, session.isReachable else {
            debugLog("[AppleWatchActor] Cannot request library - watch not reachable")
            return
        }

        let message: [String: Any] = ["type": "requestLibrary"]
        session.sendMessage(
            message,
            replyHandler: { [weak self] response in
                guard let self else { return }
                let booksData = response["books"] as? Data
                self.processLibraryResponse(booksData: booksData)
            },
            errorHandler: { error in
                debugLog("[AppleWatchActor] Failed to request library: \(error)")
            }
        )
    }

    nonisolated private func processLibraryResponse(booksData: Data?) {
        Task {
            await handleLibraryResponse(booksData: booksData)
        }
    }

    private func handleLibraryResponse(booksData: Data?) {
        guard let data = booksData else { return }

        do {
            let books = try JSONDecoder().decode([WatchBookInfo].self, from: data)
            watchBooks = books
            notifyObservers(.watchBooksUpdated(books: books))
            debugLog("[AppleWatchActor] Received \(books.count) books from watch")
        } catch {
            debugLog("[AppleWatchActor] Failed to decode watch library: \(error)")
        }
    }

    public func deleteBookFromWatch(bookUUID: String, category: LocalMediaCategory) {
        guard let session, session.activationState == .activated else { return }

        let message: [String: Any] = [
            "type": "deleteBook",
            "uuid": bookUUID,
            "category": category.rawValue,
        ]

        session.sendMessage(
            message,
            replyHandler: { [weak self] _ in
                self?.triggerLibraryRefresh()
            },
            errorHandler: { error in
                debugLog("[AppleWatchActor] Failed to delete book from watch: \(error)")
            }
        )
    }

    nonisolated private func triggerLibraryRefresh() {
        Task {
            await requestWatchLibrary()
        }
    }

    private func handleTransferComplete(transferId: String) {
        guard var item = pendingTransfers.removeValue(forKey: transferId) else { return }

        chunksCompleted.removeValue(forKey: transferId)
        chunksExpected.removeValue(forKey: transferId)

        item = WatchTransferItem(
            id: item.id,
            bookUUID: item.bookUUID,
            bookTitle: item.bookTitle,
            category: item.category,
            state: .completed,
            totalBytes: item.totalBytes,
            transferredBytes: item.totalBytes,
            startedAt: item.startedAt,
            completedAt: Date()
        )

        completedTransfers[transferId] = item
        notifyObservers(.stateChanged(item: item))
        notifyObservers(.transfersUpdated(items: getPendingTransfers()))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch_chunks_\(transferId)",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: tempDir)

        requestWatchLibrary()
    }

    private func handleChunkSent(transferId: String) {
        guard var item = pendingTransfers[transferId] else { return }

        let completed = (chunksCompleted[transferId] ?? 0) + 1
        chunksCompleted[transferId] = completed

        let expected = chunksExpected[transferId] ?? kChunkCount
        let progress = Double(completed) / Double(expected)
        let transferred = Int64(Double(item.totalBytes) * progress)

        debugLog("[AppleWatchActor] Chunk sent: \(completed)/\(expected) for \(transferId)")

        if completed >= expected {
            handleTransferComplete(transferId: transferId)
        } else {
            item = WatchTransferItem(
                id: item.id,
                bookUUID: item.bookUUID,
                bookTitle: item.bookTitle,
                category: item.category,
                state: .transferring(progress: progress),
                totalBytes: item.totalBytes,
                transferredBytes: transferred,
                startedAt: item.startedAt,
                completedAt: nil
            )

            pendingTransfers[transferId] = item
            notifyObservers(.stateChanged(item: item))
        }
    }

    // MARK: - Remote Playback Control

    public func startObservingSMILPlayer() {
        guard smilObserverId == nil else { return }

        let observerId = UUID()
        smilObserverId = observerId

        Task {
            await SMILPlayerActor.shared.addStateObserver(id: observerId) { [weak self] state in
                Task {
                    await self?.handleSMILStateChange(state)
                }
            }
        }
        debugLog("[AppleWatchActor] Started observing SMIL player state")
    }

    public func stopObservingSMILPlayer() {
        guard let observerId = smilObserverId else { return }
        smilObserverId = nil

        Task {
            await SMILPlayerActor.shared.removeStateObserver(id: observerId)
        }
        debugLog("[AppleWatchActor] Stopped observing SMIL player state")
    }

    @MainActor
    private func handleSMILStateChange(_ state: SMILPlaybackState) async {
        await sendPlaybackStateToWatch()
    }

    public func sendPlaybackStateToWatch() async {
        guard let session, session.isReachable else { return }

        let stateData = await buildRemotePlaybackState()

        var message: [String: Any] = ["type": "playbackState"]
        if let data = stateData {
            message["state"] = data
        }

        session.sendMessage(
            message,
            replyHandler: nil,
            errorHandler: { error in
                debugLog("[AppleWatchActor] Failed to send playback state: \(error)")
            }
        )
    }

    private func buildRemotePlaybackState() async -> Data? {
        guard let smilState = await SMILPlayerActor.shared.getCurrentState(),
            let bookId = smilState.bookId
        else { return nil }

        let structure = await SMILPlayerActor.shared.getBookStructure()
        let bookTitle = await SMILPlayerActor.shared.getLoadedBookTitle() ?? "Unknown"

        let chapters =
            structure
            .filter { !$0.mediaOverlay.isEmpty }
            .enumerated()
            .map { (idx, section) in
                RemoteChapter(
                    index: idx,
                    title: section.label ?? "Chapter \(idx + 1)",
                    sectionIndex: section.index
                )
            }
        cachedChapters = chapters

        let currentChapterIndex =
            chapters.firstIndex { $0.sectionIndex == smilState.currentSectionIndex } ?? 0

        let remoteState = RemotePlaybackState(
            bookTitle: bookTitle,
            bookId: bookId,
            chapterTitle: smilState.chapterLabel ?? "Chapter \(currentChapterIndex + 1)",
            currentChapterIndex: currentChapterIndex,
            chapters: chapters,
            isPlaying: smilState.isPlaying,
            chapterElapsed: smilState.chapterElapsed,
            chapterDuration: smilState.chapterTotal,
            bookElapsed: smilState.bookElapsed,
            bookDuration: smilState.bookTotal,
            playbackRate: smilState.playbackRate,
            volume: smilState.volume
        )

        return try? JSONEncoder().encode(remoteState)
    }

    private func handlePlaybackControlCommand(command: String, intValue: Int?, doubleValue: Double?)
        async
    {
        do {
            switch command {
                case "togglePlayPause":
                    try await SMILPlayerActor.shared.togglePlayPause()
                case "skipForward":
                    await SMILPlayerActor.shared.skipForward(seconds: 30)
                case "skipBackward":
                    await SMILPlayerActor.shared.skipBackward(seconds: 30)
                case "seekToChapter":
                    if let sectionIndex = intValue {
                        try await SMILPlayerActor.shared.seekToEntry(
                            sectionIndex: sectionIndex,
                            entryIndex: 0
                        )
                    }
                case "setPlaybackRate":
                    if let rate = doubleValue {
                        await SMILPlayerActor.shared.setPlaybackRate(rate)
                    } else if let rate = intValue {
                        await SMILPlayerActor.shared.setPlaybackRate(Double(rate))
                    }
                case "setVolume":
                    if let volume = doubleValue {
                        await SMILPlayerActor.shared.setVolume(volume)
                    } else if let volume = intValue {
                        await SMILPlayerActor.shared.setVolume(Double(volume))
                    }
                default:
                    debugLog("[AppleWatchActor] Unknown playback command: \(command)")
            }
        } catch {
            debugLog("[AppleWatchActor] Playback command failed: \(error)")
        }
    }
}

extension AppleWatchActor: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task {
            await self.handleActivationComplete(activationState: activationState, error: error)
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
        debugLog("[AppleWatchActor] Session became inactive")
    }

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        debugLog("[AppleWatchActor] Session deactivated")
        Task {
            await self.activate()
        }
    }
    #endif

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task {
            await self.handleReachabilityChange(isReachable: isReachable)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any])
    {
        let messageType = message["type"] as? String

        if messageType == "playbackControl" {
            if let command = message["command"] as? String {
                let intValue = message["value"] as? Int
                let doubleValue = message["value"] as? Double
                Task {
                    await self.handlePlaybackControlCommand(
                        command: command,
                        intValue: intValue,
                        doubleValue: doubleValue
                    )
                }
            }
            return
        }

        let uuid = message["uuid"] as? String
        let category = message["category"] as? String
        Task {
            await self.handleMessage(type: messageType, uuid: uuid, category: category)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let messageType = message["type"] as? String
        switch messageType {
            case "ping":
                replyHandler(["status": "ok"])
            case "requestPlaybackState":
                let sendableReply = SendableReplyHandler(replyHandler)
                Task {
                    let stateData = await self.buildRemotePlaybackState()
                    let response: [String: Any]
                    if let data = stateData {
                        response = ["state": data]
                    } else {
                        response = ["state": NSNull()]
                    }
                    sendableReply.reply(response)
                }
            case "playbackControl":
                if let command = message["command"] as? String {
                    let intValue = message["value"] as? Int
                    let doubleValue = message["value"] as? Double
                    Task {
                        await self.handlePlaybackControlCommand(
                            command: command,
                            intValue: intValue,
                            doubleValue: doubleValue
                        )
                    }
                }
                replyHandler(["status": "ok"])
            default:
                replyHandler(["error": "Unhandled message type"])
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let transferId = fileTransfer.file.metadata?["transferId"] as? String
        let errorMessage = error?.localizedDescription
        debugLog(
            "[AppleWatchActor] didFinish called - transferId: \(transferId ?? "nil"), error: \(errorMessage ?? "none")"
        )
        Task {
            await self.handleFileTransferComplete(
                transferId: transferId,
                errorMessage: errorMessage
            )
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let messageType = userInfo["type"] as? String
        let uuid = userInfo["uuid"] as? String
        let category = userInfo["category"] as? String
        debugLog("[AppleWatchActor] didReceiveUserInfo - type: \(messageType ?? "nil")")
        Task {
            await self.handleMessage(type: messageType, uuid: uuid, category: category)
        }
    }

    private func handleActivationComplete(activationState: WCSessionActivationState, error: Error?)
    {
        isActivated = activationState == .activated
        if let error {
            debugLog("[AppleWatchActor] Activation failed: \(error)")
        } else {
            debugLog("[AppleWatchActor] Session activated: \(activationState.rawValue)")

            // Clear any stuck transfers from previous sessions
            if let session {
                let stuckCount = session.outstandingFileTransfers.count
                if stuckCount > 0 {
                    debugLog(
                        "[AppleWatchActor] Clearing \(stuckCount) stuck transfers from previous session"
                    )
                    for transfer in session.outstandingFileTransfers {
                        transfer.cancel()
                    }
                }
            }

            requestWatchLibrary()
            if session?.isReachable == true {
                startObservingSMILPlayer()
            }
        }
    }

    private func handleReachabilityChange(isReachable: Bool) {
        notifyObservers(.watchReachabilityChanged(isReachable: isReachable))
        if isReachable {
            requestWatchLibrary()
            startObservingSMILPlayer()
        } else {
            stopObservingSMILPlayer()
        }
    }

    private func handleFileTransferComplete(transferId: String?, errorMessage: String?) {
        guard let transferId else {
            debugLog("[AppleWatchActor] File transfer completed without transfer ID")
            return
        }

        if let errorMessage {
            debugLog("[AppleWatchActor] Chunk transfer failed: \(errorMessage)")
            if var item = pendingTransfers[transferId] {
                item = updateItem(item, state: .failed(message: errorMessage))
                _ = item
            }
            chunksCompleted.removeValue(forKey: transferId)
        } else {
            handleChunkSent(transferId: transferId)
        }
    }

    private func handleMessage(type: String?, uuid: String?, category: String?) {
        guard let type else { return }

        switch type {
            case "transferComplete":
                if let uuid, let category {
                    let transferId = "\(uuid)-\(category)"
                    debugLog(
                        "[AppleWatchActor] Watch confirmed all chunks received for: \(transferId)"
                    )
                    handleTransferComplete(transferId: transferId)
                }
            case "cancelTransfer":
                if let uuid, let category, let cat = LocalMediaCategory(rawValue: category) {
                    debugLog(
                        "[AppleWatchActor] Watch requested transfer cancellation: \(uuid) \(category)"
                    )
                    for (transferId, item) in pendingTransfers {
                        if item.bookUUID == uuid && item.category == cat {
                            cancelTransfer(transferId: transferId)
                            break
                        }
                    }
                }
            case "libraryUpdated":
                requestWatchLibrary()
            default:
                debugLog("[AppleWatchActor] Unknown message type: \(type)")
        }
    }

}

struct SendableReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func reply(_ response: [String: Any]) {
        handler(response)
    }
}

struct ChunkTransferMetadata: Codable, Sendable {
    let uuid: String
    let title: String
    let authors: [String]
    let category: String
    let chunkIndex: Int
    let totalChunks: Int
    let totalFileSize: Int64
    let fileExtension: String
}

enum WatchTransferError: Error, LocalizedError {
    case sessionNotActive
    case watchNotPaired
    case failedToOpenArchive(String)
    case transferFailed(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
            case .sessionNotActive:
                return "Watch session is not active"
            case .watchNotPaired:
                return "No Apple Watch is paired"
            case .failedToOpenArchive(let path):
                return "Failed to open archive: \(path)"
            case .transferFailed(let reason):
                return "Transfer failed: \(reason)"
            case .fileNotFound(let path):
                return "File not found: \(path)"
        }
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

    public func cancelTransfer(transferId: String) {}
    public func removeCompletedTransfer(transferId: String) {}
    public func requestWatchLibrary() {}
    public func deleteBookFromWatch(bookUUID: String, category: LocalMediaCategory) {}
}

enum WatchTransferError: Error, LocalizedError {
    case notSupported

    var errorDescription: String? {
        "Apple Watch transfers not supported on this platform"
    }
}

#endif
