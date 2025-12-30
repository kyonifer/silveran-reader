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

    private static let maxHistoryEntriesPerBook = 20

    private var pendingProgressQueue: [PendingProgressSync] = []
    /// Latest known server position for each book. Updated when LMA loads metadata from server/disk,
    /// or when we successfully sync a position to the server.
    private var serverPositions: [String: BookReadingPosition] = [:]
    private var lastWakeTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var queueLoaded = false
    private var historyLoaded = false

    private var syncHistory: [String: [SyncHistoryEntry]] = [:]

    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var syncNotificationCallback: (@Sendable @MainActor (Int, Int) -> Void)?

    public init() {
        Task {
            await loadQueueFromDisk()
            await loadHistoryFromDisk()
        }
    }

    private func ensureQueueLoaded() async {
        guard !queueLoaded else { return }
        await loadQueueFromDisk()
    }

    private func ensureHistoryLoaded() async {
        guard !historyLoaded else { return }
        await loadHistoryFromDisk()
    }

    // MARK: - Primary API

    /// Sync progress with full introspection data for debugging.
    /// - Parameters:
    ///   - bookId: The book's unique identifier
    ///   - locator: The reading position
    ///   - timestamp: Unix millisecond timestamp of the position
    ///   - reason: Why this sync was triggered
    ///   - sourceIdentifier: Human-readable source like "CarPlay/Audiobook", "Ebook Player"
    ///   - locationDescription: Human-readable position like "Chapter 3, 22%"
    public func syncProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
        reason: SyncReason,
        sourceIdentifier: String = "Unknown",
        locationDescription: String = ""
    ) async -> SyncResult {
        debugLog(
            "[PSA] syncProgress: bookId=\(bookId), reason=\(reason.rawValue), timestamp=\(timestamp), source=\(sourceIdentifier)"
        )

        if shouldDedupe(bookId: bookId, locator: locator, timestamp: timestamp) {
            debugLog("[PSA] syncProgress: deduplicated, skipping")
            return .success
        }

        let locatorSummary = buildLocatorSummary(locator)

        let isLocalBook = await LocalMediaActor.shared.isLocalStandaloneBook(bookId)
        if isLocalBook {
            debugLog("[PSA] syncProgress: local-only book, updating state without server sync")
            updateServerPositionIfNewer(bookId: bookId, locator: locator, timestamp: timestamp)
            await updateLocalMetadataProgress(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
            await addHistoryEntry(
                bookId: bookId,
                timestamp: timestamp,
                sourceIdentifier: sourceIdentifier,
                locationDescription: locationDescription,
                reason: reason,
                result: .persisted,
                locatorSummary: locatorSummary
            )
            return .success
        }

        // ALWAYS persist to queue first for durability
        await queueOfflineProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
            syncedToStoryteller: false
        )
        await updateLocalMetadataProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp
        )

        await addHistoryEntry(
            bookId: bookId,
            timestamp: timestamp,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
            reason: reason,
            result: .persisted,
            locatorSummary: locatorSummary
        )

        // Now attempt server sync if connected
        let storytellerStatus = await StorytellerActor.shared.connectionStatus
        debugLog("[PSA] syncProgress: storytellerStatus=\(storytellerStatus)")

        if storytellerStatus == .connected {
            let result = await StorytellerActor.shared.sendProgressToServer(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
            if result == .success {
                debugLog("[PSA] syncProgress: synced to server")
                await markQueueItemSynced(bookId: bookId)
                updateServerPositionIfNewer(bookId: bookId, locator: locator, timestamp: timestamp)
                await updateHistoryResult(bookId: bookId, timestamp: timestamp, result: .sentToServer)
                await notifyObservers()
                return .success
            }
            debugLog("[PSA] syncProgress: server sync failed, result=\(result)")
        }

        debugLog("[PSA] syncProgress: queued for later sync")
        await notifyObservers()
        return .queued
    }

    private func buildLocatorSummary(_ locator: BookLocator) -> String {
        var parts: [String] = []
        parts.append("href: \(locator.href)")
        if let fragments = locator.locations?.fragments, !fragments.isEmpty {
            parts.append("fragments: \(fragments.joined(separator: ", "))")
        }
        if let prog = locator.locations?.totalProgression {
            parts.append("total: \(String(format: "%.1f%%", prog * 100))")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Queue Management

    public func syncPendingQueue() async -> (synced: Int, failed: Int) {
        debugLog("[PSA] syncPendingQueue: starting with \(pendingProgressQueue.count) items")

        guard !pendingProgressQueue.isEmpty else {
            debugLog("[PSA] syncPendingQueue: queue empty")
            return (0, 0)
        }

        let storytellerStatus = await StorytellerActor.shared.connectionStatus
        guard storytellerStatus == .connected else {
            debugLog("[PSA] syncPendingQueue: server not connected, skipping")
            return (0, 0)
        }

        var syncedCount = 0
        var failedCount = 0

        let queueSnapshot = pendingProgressQueue
        for var pending in queueSnapshot {
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
                "[PSA] syncPendingQueue: syncing \(pending.bookId) (synced=\(pending.syncedToStoryteller))"
            )

            if !pending.syncedToStoryteller {
                let result = await StorytellerActor.shared.sendProgressToServer(
                    bookId: pending.bookId,
                    locator: pending.locator,
                    timestamp: pending.timestamp
                )
                if result == .success {
                    pending.syncedToStoryteller = true
                    updateServerPositionIfNewer(
                        bookId: pending.bookId,
                        locator: pending.locator,
                        timestamp: pending.timestamp
                    )
                    debugLog("[PSA] syncPendingQueue: \(pending.bookId) sync succeeded")
                } else if result == .failure {
                    pending.syncedToStoryteller = true
                    debugLog(
                        "[PSA] syncPendingQueue: \(pending.bookId) sync failed permanently"
                    )
                    failedCount += 1
                }
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

    /// Called by LMA when metadata updates from server or disk.
    /// Performs timestamp-based reconciliation: only updates if incoming is newer than local,
    /// and removes pending queue items if server has confirmed a newer position.
    public func updateServerPositions(_ positions: [String: BookReadingPosition]) async {
        await ensureQueueLoaded()
        await ensureHistoryLoaded()
        var updatedCount = 0
        var reconciledCount = 0

        for (bookId, incomingPosition) in positions {
            let incomingTimestamp = incomingPosition.timestamp ?? 0
            guard incomingTimestamp > 0 else { continue }

            // Skip if we already have this exact position (same timestamp)
            if let existing = serverPositions[bookId], existing.timestamp == incomingTimestamp {
                continue
            }

            // Skip if this matches a pending sync (likely echo of our own outgoing sync)
            if let pending = pendingProgressQueue.first(where: { $0.bookId == bookId }),
               pending.timestamp == incomingTimestamp {
                debugLog("[PSA] updateServerPositions: skipping \(bookId), matches pending sync timestamp")
                continue
            }

            let locatorSummary = incomingPosition.locator.map { buildLocatorSummary($0) } ?? "no locator"
            let locationDesc = buildLocationDescription(from: incomingPosition.locator)

            // Check if we have a pending sync for this book
            if let pendingIndex = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
                let pending = pendingProgressQueue[pendingIndex]
                if incomingTimestamp > pending.timestamp {
                    // Server has newer data, remove from pending queue
                    debugLog("[PSA] updateServerPositions: server newer for \(bookId), removing pending (server: \(incomingTimestamp), pending: \(pending.timestamp))")
                    pendingProgressQueue.remove(at: pendingIndex)
                    serverPositions[bookId] = incomingPosition
                    reconciledCount += 1
                    updatedCount += 1

                    await addHistoryEntry(
                        bookId: bookId,
                        timestamp: incomingTimestamp,
                        sourceIdentifier: "Server",
                        locationDescription: locationDesc,
                        reason: .connectionRestored,
                        result: .serverIncomingAccepted,
                        locatorSummary: locatorSummary
                    )
                } else {
                    // Pending is newer, keep pending and don't overwrite serverPositions
                    debugLog("[PSA] updateServerPositions: pending newer for \(bookId), keeping pending (server: \(incomingTimestamp), pending: \(pending.timestamp))")

                    await addHistoryEntry(
                        bookId: bookId,
                        timestamp: incomingTimestamp,
                        sourceIdentifier: "Server",
                        locationDescription: locationDesc,
                        reason: .connectionRestored,
                        result: .serverIncomingRejected,
                        locatorSummary: "rejected: pending is newer (\(pending.timestamp) > \(incomingTimestamp))"
                    )
                }
            } else {
                // No pending sync, check existing server position
                if let existing = serverPositions[bookId] {
                    let existingTimestamp = existing.timestamp ?? 0
                    if incomingTimestamp > existingTimestamp {
                        serverPositions[bookId] = incomingPosition
                        updatedCount += 1

                        await addHistoryEntry(
                            bookId: bookId,
                            timestamp: incomingTimestamp,
                            sourceIdentifier: "Server",
                            locationDescription: locationDesc,
                            reason: .connectionRestored,
                            result: .serverIncomingAccepted,
                            locatorSummary: locatorSummary
                        )
                    } else {
                        debugLog("[PSA] updateServerPositions: existing newer for \(bookId), skipping (incoming: \(incomingTimestamp), existing: \(existingTimestamp))")

                        await addHistoryEntry(
                            bookId: bookId,
                            timestamp: incomingTimestamp,
                            sourceIdentifier: "Server",
                            locationDescription: locationDesc,
                            reason: .connectionRestored,
                            result: .serverIncomingRejected,
                            locatorSummary: "rejected: local is newer (\(existingTimestamp) >= \(incomingTimestamp))"
                        )
                    }
                } else {
                    // No existing position, just set it
                    serverPositions[bookId] = incomingPosition
                    updatedCount += 1

                    await addHistoryEntry(
                        bookId: bookId,
                        timestamp: incomingTimestamp,
                        sourceIdentifier: "Server",
                        locationDescription: locationDesc,
                        reason: .connectionRestored,
                        result: .serverIncomingAccepted,
                        locatorSummary: locatorSummary
                    )
                }
            }
        }

        if reconciledCount > 0 {
            await saveQueueToDisk()
        }

        debugLog(
            "[PSA] updateServerPositions: updated \(updatedCount), reconciled \(reconciledCount), total=\(serverPositions.count)"
        )
    }

    private func buildLocationDescription(from locator: BookLocator?) -> String {
        guard let locator = locator else { return "" }
        if let prog = locator.locations?.totalProgression {
            let title = locator.title ?? "Unknown"
            return "\(title), \(Int(prog * 100))%"
        }
        return locator.title ?? ""
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

    private func updateServerPositionIfNewer(bookId: String, locator: BookLocator, timestamp: Double) {
        if let existing = serverPositions[bookId], let existingTimestamp = existing.timestamp {
            if timestamp <= existingTimestamp {
                debugLog("[PSA] updateServerPositionIfNewer: existing is newer, skipping (incoming: \(timestamp), existing: \(existingTimestamp))")
                return
            }
        }

        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()
        serverPositions[bookId] = BookReadingPosition(
            uuid: serverPositions[bookId]?.uuid,
            locator: locator,
            timestamp: timestamp,
            createdAt: serverPositions[bookId]?.createdAt,
            updatedAt: updatedAtString
        )
        debugLog("[PSA] updateServerPositionIfNewer: bookId=\(bookId), timestamp=\(timestamp)")
    }

    private func queueOfflineProgress(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
        syncedToStoryteller: Bool = false
    ) async {
        // Only replace if incoming is newer
        if let existingIndex = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
            let existing = pendingProgressQueue[existingIndex]
            if timestamp <= existing.timestamp {
                debugLog("[PSA] queueOfflineProgress: existing pending is newer, skipping (incoming: \(timestamp), existing: \(existing.timestamp))")
                return
            }
            pendingProgressQueue.remove(at: existingIndex)
        }

        let pending = PendingProgressSync(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
            syncedToStoryteller: syncedToStoryteller
        )
        pendingProgressQueue.append(pending)

        debugLog(
            "[PSA] queueOfflineProgress: bookId=\(bookId), queueSize=\(pendingProgressQueue.count), synced=\(syncedToStoryteller)"
        )

        await saveQueueToDisk()
        await notifyObservers()
    }

    private func markQueueItemSynced(bookId: String) async {
        if let index = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
            pendingProgressQueue[index].syncedToStoryteller = true
            debugLog("[PSA] markQueueItemSynced: bookId=\(bookId)")
            await saveQueueToDisk()
        }
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

    // MARK: - Sync History

    private func addHistoryEntry(
        bookId: String,
        timestamp: Double,
        sourceIdentifier: String,
        locationDescription: String,
        reason: SyncReason,
        result: SyncHistoryEntry.SyncHistoryResult,
        locatorSummary: String
    ) async {
        await ensureHistoryLoaded()

        let entry = SyncHistoryEntry(
            timestamp: timestamp,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
            reason: reason,
            result: result,
            locatorSummary: locatorSummary
        )

        var entries = syncHistory[bookId] ?? []
        entries.append(entry)

        // Keep only the most recent entries
        if entries.count > Self.maxHistoryEntriesPerBook {
            entries = Array(entries.suffix(Self.maxHistoryEntriesPerBook))
        }

        syncHistory[bookId] = entries
        await saveHistoryToDisk()
    }

    private func updateHistoryResult(
        bookId: String,
        timestamp: Double,
        result: SyncHistoryEntry.SyncHistoryResult
    ) async {
        await ensureHistoryLoaded()

        guard var entries = syncHistory[bookId] else { return }

        // Find the most recent entry with matching timestamp and update its result
        if let index = entries.lastIndex(where: { $0.timestamp == timestamp }) {
            let existing = entries[index]
            entries[index] = SyncHistoryEntry(
                timestamp: existing.timestamp,
                sourceIdentifier: existing.sourceIdentifier,
                locationDescription: existing.locationDescription,
                reason: existing.reason,
                result: result,
                locatorSummary: existing.locatorSummary
            )
            syncHistory[bookId] = entries
            await saveHistoryToDisk()
        }
    }

    /// Get sync history for a specific book (for debugging UI)
    public func getSyncHistory(for bookId: String) async -> [SyncHistoryEntry] {
        await ensureHistoryLoaded()
        return syncHistory[bookId] ?? []
    }

    /// Get all sync history (for debugging)
    public func getAllSyncHistory() async -> [String: [SyncHistoryEntry]] {
        await ensureHistoryLoaded()
        return syncHistory
    }

    /// Clear sync history for a book
    public func clearSyncHistory(for bookId: String) async {
        syncHistory.removeValue(forKey: bookId)
        await saveHistoryToDisk()
    }

    private func loadHistoryFromDisk() async {
        guard !historyLoaded else { return }
        do {
            syncHistory = try await FilesystemActor.shared.loadSyncHistory()
            debugLog("[PSA] loadHistoryFromDisk: loaded history for \(syncHistory.count) books")
        } catch {
            debugLog("[PSA] loadHistoryFromDisk: failed - \(error)")
            syncHistory = [:]
        }
        historyLoaded = true
    }

    private func saveHistoryToDisk() async {
        do {
            try await FilesystemActor.shared.saveSyncHistory(syncHistory)
            debugLog("[PSA] saveHistoryToDisk: saved history for \(syncHistory.count) books")
        } catch {
            debugLog("[PSA] saveHistoryToDisk: failed - \(error)")
        }
    }
}
