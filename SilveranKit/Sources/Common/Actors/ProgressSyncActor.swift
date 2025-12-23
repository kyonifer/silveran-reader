import Foundation

public struct BookProgress: Sendable {
    public let bookId: String
    public let locator: BookLocator?
    public let timestamp: Double?
    public let source: ProgressSource

    public enum ProgressSource: Sendable {
        case server
        case pendingSync
        case localOnly
    }

    public var progressFraction: Double {
        let raw =
            locator?.locations?.totalProgression
            ?? locator?.locations?.progression
            ?? 0
        return min(max(raw, 0), 1)
    }

    public init(
        bookId: String,
        locator: BookLocator?,
        timestamp: Double?,
        source: ProgressSource
    ) {
        self.bookId = bookId
        self.locator = locator
        self.timestamp = timestamp
        self.source = source
    }
}

@globalActor
public actor ProgressSyncActor {
    public static let shared = ProgressSyncActor()

    private var pendingProgressQueue: [PendingProgressSync] = []
    /// Latest known server position for each book. Updated when LMA loads metadata from server/disk,
    /// or when we successfully sync a position to the server.
    private var serverPositions: [String: BookReadingPosition] = [:]
    private var lastWakeTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var queueLoaded = false

    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var syncNotificationCallback: (@Sendable @MainActor (Int, Int) -> Void)?

    public init() {
        Task {
            await loadQueueFromDisk()
        }
    }

    private func ensureQueueLoaded() async {
        guard !queueLoaded else { return }
        await loadQueueFromDisk()
    }

    // MARK: - Primary API

    public func syncProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
        reason: SyncReason
    ) async -> SyncResult {
        debugLog(
            "[PSA] syncProgress: bookId=\(bookId), reason=\(reason.rawValue), timestamp=\(timestamp)"
        )

        if shouldDedupe(bookId: bookId, locator: locator, timestamp: timestamp) {
            debugLog("[PSA] syncProgress: deduplicated, skipping")
            return .success
        }

        let isLocalBook = await LocalMediaActor.shared.isLocalStandaloneBook(bookId)
        if isLocalBook {
            debugLog("[PSA] syncProgress: local-only book, updating state without server sync")
            updateServerPosition(bookId: bookId, locator: locator, timestamp: timestamp)
            return .success
        }

        let iCloudSyncEnabled = await SettingsActor.shared.config.sync.iCloudSyncEnabled

        var syncedToStoryteller = false
        var syncedToCloudKit = false

        let storytellerStatus = await StorytellerActor.shared.connectionStatus
        debugLog("[PSA] syncProgress: storytellerStatus=\(storytellerStatus)")

        if storytellerStatus == .connected {
            let result = await StorytellerActor.shared.sendProgressToServer(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
            syncedToStoryteller = (result == .success)
            debugLog(
                "[PSA] syncProgress: storyteller sync result=\(result), success=\(syncedToStoryteller)"
            )
        }

        if iCloudSyncEnabled {
            let cloudKitStatus = await CloudKitSyncActor.shared.connectionStatus
            debugLog("[PSA] syncProgress: cloudKitStatus=\(cloudKitStatus)")

            if cloudKitStatus == .connected {
                let result = await CloudKitSyncActor.shared.sendProgressToCloudKit(
                    bookId: bookId,
                    locator: locator,
                    timestamp: timestamp
                )
                syncedToCloudKit = (result == .success)
                debugLog(
                    "[PSA] syncProgress: cloudKit sync result=\(result), success=\(syncedToCloudKit)"
                )
            }
        } else {
            syncedToCloudKit = true
        }

        let isFullySynced = syncedToStoryteller && syncedToCloudKit

        if isFullySynced {
            debugLog("[PSA] syncProgress: fully synced to all destinations")
            await removeFromQueue(bookId: bookId)
            updateServerPosition(bookId: bookId, locator: locator, timestamp: timestamp)
            await updateLocalMetadataProgress(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
            await notifyObservers()
            return .success
        } else {
            debugLog(
                "[PSA] syncProgress: partial sync, queueing (storyteller=\(syncedToStoryteller), cloudKit=\(syncedToCloudKit))"
            )
            await queueOfflineProgress(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp,
                syncedToStoryteller: syncedToStoryteller,
                syncedToCloudKit: syncedToCloudKit
            )
            if syncedToStoryteller {
                updateServerPosition(bookId: bookId, locator: locator, timestamp: timestamp)
            }
            await updateLocalMetadataProgress(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
            return .queued
        }
    }

    // MARK: - Queue Management

    public func syncPendingQueue() async -> (synced: Int, failed: Int) {
        debugLog("[PSA] syncPendingQueue: starting with \(pendingProgressQueue.count) items")

        guard !pendingProgressQueue.isEmpty else {
            debugLog("[PSA] syncPendingQueue: queue empty")
            return (0, 0)
        }

        let storytellerStatus = await StorytellerActor.shared.connectionStatus
        let cloudKitStatus = await CloudKitSyncActor.shared.connectionStatus
        let iCloudSyncEnabled = await SettingsActor.shared.config.sync.iCloudSyncEnabled

        let canSyncStoryteller = storytellerStatus == .connected
        let canSyncCloudKit = iCloudSyncEnabled && cloudKitStatus == .connected

        if !canSyncStoryteller && !canSyncCloudKit {
            debugLog("[PSA] syncPendingQueue: no destinations available, skipping")
            return (0, 0)
        }

        var syncedCount = 0
        var failedCount = 0

        for i in pendingProgressQueue.indices {
            var pending = pendingProgressQueue[i]

            let isLocalBook = await LocalMediaActor.shared.isLocalStandaloneBook(pending.bookId)
            if isLocalBook {
                debugLog(
                    "[PSA] syncPendingQueue: \(pending.bookId) is local-only, removing from queue"
                )
                await removeFromQueue(bookId: pending.bookId)
                syncedCount += 1
                continue
            }

            debugLog(
                "[PSA] syncPendingQueue: syncing \(pending.bookId) (storyteller=\(pending.syncedToStoryteller), cloudKit=\(pending.syncedToCloudKit))"
            )

            if !pending.syncedToStoryteller && canSyncStoryteller {
                let result = await StorytellerActor.shared.sendProgressToServer(
                    bookId: pending.bookId,
                    locator: pending.locator,
                    timestamp: pending.timestamp
                )
                if result == .success {
                    pending.syncedToStoryteller = true
                    updateServerPosition(
                        bookId: pending.bookId,
                        locator: pending.locator,
                        timestamp: pending.timestamp
                    )
                    debugLog("[PSA] syncPendingQueue: \(pending.bookId) storyteller succeeded")
                } else if result == .failure {
                    pending.syncedToStoryteller = true
                    debugLog(
                        "[PSA] syncPendingQueue: \(pending.bookId) storyteller failed permanently"
                    )
                    failedCount += 1
                }
            }

            if !pending.syncedToCloudKit && canSyncCloudKit {
                let result = await CloudKitSyncActor.shared.sendProgressToCloudKit(
                    bookId: pending.bookId,
                    locator: pending.locator,
                    timestamp: pending.timestamp
                )
                if result == .success {
                    pending.syncedToCloudKit = true
                    debugLog("[PSA] syncPendingQueue: \(pending.bookId) cloudKit succeeded")
                } else if result == .failure {
                    pending.syncedToCloudKit = true
                    debugLog(
                        "[PSA] syncPendingQueue: \(pending.bookId) cloudKit failed permanently"
                    )
                }
            }

            if !iCloudSyncEnabled {
                pending.syncedToCloudKit = true
            }

            if pending.isFullySynced {
                debugLog("[PSA] syncPendingQueue: \(pending.bookId) fully synced, removing")
                await removeFromQueue(bookId: pending.bookId)
                syncedCount += 1
            } else {
                await updateQueueItem(pending)
            }
        }

        debugLog("[PSA] syncPendingQueue: complete - synced=\(syncedCount), failed=\(failedCount)")

        if syncedCount > 0 || failedCount > 0 {
            await notifyObservers()
            await syncNotificationCallback?(syncedCount, failedCount)
        }

        return (syncedCount, failedCount)
    }

    private func updateQueueItem(_ item: PendingProgressSync) async {
        if let index = pendingProgressQueue.firstIndex(where: { $0.bookId == item.bookId }) {
            pendingProgressQueue[index] = item
            await saveQueueToDisk()
        }
    }

    public func getPendingProgressSyncs() async -> [PendingProgressSync] {
        await ensureQueueLoaded()
        return pendingProgressQueue
    }

    public func hasPendingSync(for bookId: String) -> Bool {
        pendingProgressQueue.contains { $0.bookId == bookId }
    }

    // MARK: - CloudKit Reconciliation

    public func reconcileWithCloudKit() async {
        let iCloudSyncEnabled = await SettingsActor.shared.config.sync.iCloudSyncEnabled
        guard iCloudSyncEnabled else {
            debugLog("[PSA] reconcileWithCloudKit: iCloud sync disabled, skipping")
            return
        }

        let cloudKitStatus = await CloudKitSyncActor.shared.connectionStatus
        guard cloudKitStatus == .connected else {
            debugLog("[PSA] reconcileWithCloudKit: CloudKit not connected, skipping")
            return
        }

        debugLog("[PSA] reconcileWithCloudKit: fetching CloudKit positions")

        guard let cloudKitPositions = await CloudKitSyncActor.shared.fetchAllProgress() else {
            debugLog("[PSA] reconcileWithCloudKit: failed to fetch CloudKit positions")
            return
        }

        debugLog("[PSA] reconcileWithCloudKit: found \(cloudKitPositions.count) CloudKit positions")

        let storytellerStatus = await StorytellerActor.shared.connectionStatus
        var healedToStoryteller = 0
        var healedToCloudKit = 0

        for (bookId, serverPosition) in serverPositions {
            guard let locator = serverPosition.locator,
                let serverTimestamp = serverPosition.timestamp
            else { continue }

            if let cloudKitProgress = cloudKitPositions[bookId] {
                if cloudKitProgress.timestamp > serverTimestamp {
                    debugLog(
                        "[PSA] reconcileWithCloudKit: \(bookId) CloudKit is newer (\(cloudKitProgress.timestamp) > \(serverTimestamp))"
                    )
                    updateServerPosition(
                        bookId: bookId,
                        locator: cloudKitProgress.locator,
                        timestamp: cloudKitProgress.timestamp
                    )
                    await updateLocalMetadataProgress(
                        bookId: bookId,
                        locator: cloudKitProgress.locator,
                        timestamp: cloudKitProgress.timestamp
                    )

                    if storytellerStatus == .connected {
                        let result = await StorytellerActor.shared.sendProgressToServer(
                            bookId: bookId,
                            locator: cloudKitProgress.locator,
                            timestamp: cloudKitProgress.timestamp
                        )
                        if result == .success {
                            healedToStoryteller += 1
                            debugLog("[PSA] reconcileWithCloudKit: healed \(bookId) to Storyteller")
                        }
                    }
                } else if serverTimestamp > cloudKitProgress.timestamp {
                    debugLog(
                        "[PSA] reconcileWithCloudKit: \(bookId) Storyteller is newer (\(serverTimestamp) > \(cloudKitProgress.timestamp))"
                    )
                    let result = await CloudKitSyncActor.shared.sendProgressToCloudKit(
                        bookId: bookId,
                        locator: locator,
                        timestamp: serverTimestamp
                    )
                    if result == .success {
                        healedToCloudKit += 1
                        debugLog("[PSA] reconcileWithCloudKit: healed \(bookId) to CloudKit")
                    }
                }
            } else {
                debugLog("[PSA] reconcileWithCloudKit: \(bookId) not in CloudKit, pushing")
                let result = await CloudKitSyncActor.shared.sendProgressToCloudKit(
                    bookId: bookId,
                    locator: locator,
                    timestamp: serverTimestamp
                )
                if result == .success {
                    healedToCloudKit += 1
                }
            }
        }

        for (bookId, cloudKitProgress) in cloudKitPositions {
            if serverPositions[bookId] == nil {
                debugLog("[PSA] reconcileWithCloudKit: \(bookId) only in CloudKit, adopting")
                updateServerPosition(
                    bookId: bookId,
                    locator: cloudKitProgress.locator,
                    timestamp: cloudKitProgress.timestamp
                )
                await updateLocalMetadataProgress(
                    bookId: bookId,
                    locator: cloudKitProgress.locator,
                    timestamp: cloudKitProgress.timestamp
                )

                if storytellerStatus == .connected {
                    let result = await StorytellerActor.shared.sendProgressToServer(
                        bookId: bookId,
                        locator: cloudKitProgress.locator,
                        timestamp: cloudKitProgress.timestamp
                    )
                    if result == .success {
                        healedToStoryteller += 1
                    }
                }
            }
        }

        debugLog(
            "[PSA] reconcileWithCloudKit: complete - healedToStoryteller=\(healedToStoryteller), healedToCloudKit=\(healedToCloudKit)"
        )

        if healedToStoryteller > 0 || healedToCloudKit > 0 {
            await notifyObservers()
        }
    }

    // MARK: - Position Fetch

    /// Fetch current position for a book, refreshing from server if connected
    public func fetchCurrentPosition(for bookId: String) async -> BookReadingPosition? {
        debugLog("[PSA] fetchCurrentPosition: bookId=\(bookId)")

        let connectionStatus = await StorytellerActor.shared.connectionStatus
        if connectionStatus == .connected {
            debugLog("[PSA] fetchCurrentPosition: connected, refreshing from server")
            let _ = await StorytellerActor.shared.fetchLibraryInformation()
        }

        let storytellerMetadata = await LocalMediaActor.shared.localStorytellerMetadata
        let standaloneMetadata = await LocalMediaActor.shared.localStandaloneMetadata
        let allMetadata = storytellerMetadata + standaloneMetadata

        guard let book = allMetadata.first(where: { $0.uuid == bookId }) else {
            debugLog("[PSA] fetchCurrentPosition: book not found in LMA")
            return nil
        }

        debugLog(
            "[PSA] fetchCurrentPosition: returning position timestamp=\(book.position?.timestamp ?? 0)"
        )
        return book.position
    }

    // MARK: - Progress Source of Truth

    /// Called by LMA when metadata updates from server or disk
    public func updateServerPositions(_ positions: [String: BookReadingPosition]) {
        for (bookId, position) in positions {
            serverPositions[bookId] = position
        }
        debugLog(
            "[PSA] updateServerPositions: updated \(positions.count) positions, total=\(serverPositions.count)"
        )

        Task {
            await reconcileWithCloudKit()
        }
    }

    /// Get reconciled progress for all books (pending queue takes precedence over server)
    public func getAllBookProgress() async -> [String: BookProgress] {
        await ensureQueueLoaded()

        var result: [String: BookProgress] = [:]

        for (bookId, serverPosition) in serverPositions {
            if let pending = pendingProgressQueue.first(where: { $0.bookId == bookId }) {
                result[bookId] = BookProgress(
                    bookId: bookId,
                    locator: pending.locator,
                    timestamp: pending.timestamp,
                    source: .pendingSync
                )
            } else {
                result[bookId] = BookProgress(
                    bookId: bookId,
                    locator: serverPosition.locator,
                    timestamp: serverPosition.timestamp,
                    source: .server
                )
            }
        }

        for pending in pendingProgressQueue where result[pending.bookId] == nil {
            result[pending.bookId] = BookProgress(
                bookId: pending.bookId,
                locator: pending.locator,
                timestamp: pending.timestamp,
                source: .pendingSync
            )
        }

        return result
    }

    /// Get reconciled progress for a single book
    public func getBookProgress(for bookId: String) async -> BookProgress? {
        await ensureQueueLoaded()

        if let pending = pendingProgressQueue.first(where: { $0.bookId == bookId }) {
            return BookProgress(
                bookId: bookId,
                locator: pending.locator,
                timestamp: pending.timestamp,
                source: .pendingSync
            )
        }

        if let serverPosition = serverPositions[bookId] {
            return BookProgress(
                bookId: bookId,
                locator: serverPosition.locator,
                timestamp: serverPosition.timestamp,
                source: .server
            )
        }

        return nil
    }

    // MARK: - Wake Detection

    public func recordWakeEvent() {
        let now = Date().timeIntervalSince1970
        let sleepDuration = now - lastWakeTimestamp
        debugLog("[PSA] recordWakeEvent: sleepDuration=\(sleepDuration)s")
        lastWakeTimestamp = now
    }

    // MARK: - Observers

    @discardableResult
    public func addObserver(_ callback: @escaping @Sendable @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        debugLog("[PSA] addObserver: id=\(id), total observers=\(observers.count)")
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
        debugLog("[PSA] removeObserver: id=\(id), total observers=\(observers.count)")
    }

    public func registerSyncNotificationCallback(
        _ callback: @escaping @Sendable @MainActor (Int, Int) -> Void
    ) {
        syncNotificationCallback = callback
    }

    // MARK: - Private Helpers

    private func shouldDedupe(bookId: String, locator: BookLocator, timestamp: Double) -> Bool {
        guard let serverPosition = serverPositions[bookId],
            let lastLocator = serverPosition.locator
        else { return false }

        if locator.href == lastLocator.href
            && locator.locations?.fragments == lastLocator.locations?.fragments
        {
            debugLog("[PSA] shouldDedupe: same href+fragments")
            return true
        }

        return false
    }

    private func updateServerPosition(bookId: String, locator: BookLocator, timestamp: Double) {
        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()
        serverPositions[bookId] = BookReadingPosition(
            uuid: serverPositions[bookId]?.uuid,
            locator: locator,
            timestamp: timestamp,
            createdAt: serverPositions[bookId]?.createdAt,
            updatedAt: updatedAtString
        )
        debugLog("[PSA] updateServerPosition: bookId=\(bookId), timestamp=\(timestamp)")
    }

    private func queueOfflineProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
        syncedToStoryteller: Bool = false,
        syncedToCloudKit: Bool = false
    ) async {
        pendingProgressQueue.removeAll { $0.bookId == bookId }

        let pending = PendingProgressSync(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
            syncedToStoryteller: syncedToStoryteller,
            syncedToCloudKit: syncedToCloudKit
        )
        pendingProgressQueue.append(pending)

        debugLog(
            "[PSA] queueOfflineProgress: bookId=\(bookId), queueSize=\(pendingProgressQueue.count), storyteller=\(syncedToStoryteller), cloudKit=\(syncedToCloudKit)"
        )

        await saveQueueToDisk()
        await notifyObservers()
    }

    private func removeFromQueue(bookId: String) async {
        let before = pendingProgressQueue.count
        pendingProgressQueue.removeAll { $0.bookId == bookId }
        let after = pendingProgressQueue.count
        debugLog("[PSA] removeFromQueue: bookId=\(bookId), queueSize \(before) -> \(after)")
        await saveQueueToDisk()
    }

    private func updateLocalMetadataProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double
    ) async {
        await LocalMediaActor.shared.updateBookProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp
        )
    }

    private func notifyObservers() async {
        debugLog("[PSA] notifyObservers: notifying \(observers.count) observers")
        for (_, callback) in observers {
            await callback()
        }
    }

    // MARK: - Persistence

    private func loadQueueFromDisk() async {
        guard !queueLoaded else { return }
        do {
            pendingProgressQueue = try await FilesystemActor.shared.loadProgressQueue()
            debugLog("[PSA] loadQueueFromDisk: loaded \(pendingProgressQueue.count) items")
        } catch {
            debugLog("[PSA] loadQueueFromDisk: failed - \(error)")
            pendingProgressQueue = []
        }
        queueLoaded = true
    }

    private func saveQueueToDisk() async {
        do {
            try await FilesystemActor.shared.saveProgressQueue(pendingProgressQueue)
            debugLog("[PSA] saveQueueToDisk: saved \(pendingProgressQueue.count) items")
        } catch {
            debugLog("[PSA] saveQueueToDisk: failed - \(error)")
        }
    }
}
