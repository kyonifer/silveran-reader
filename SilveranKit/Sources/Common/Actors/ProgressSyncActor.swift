import Foundation

public struct IncomingServerPosition: Sendable {
    public let locator: BookLocator
    public let timestamp: Double

    public init(locator: BookLocator, timestamp: Double) {
        self.locator = locator
        self.timestamp = timestamp
    }
}

public struct BookProgress: Sendable {
    public let locator: BookLocator?
    public let timestamp: Double?
    public let source: ProgressSource

    public enum ProgressSource: Sendable {
        case server
        case pendingSync
    }

    public var progressFraction: Double {
        let raw =
            locator?.locations?.totalProgression
            ?? locator?.locations?.progression
            ?? 0
        return min(max(raw, 0), 1)
    }

    public init(
        locator: BookLocator?,
        timestamp: Double?,
        source: ProgressSource,
    ) {
        self.locator = locator
        self.timestamp = timestamp
        self.source = source
    }
}

@globalActor
public actor ProgressSyncActor {
    public static let shared = ProgressSyncActor()

    private static let maxHistoryEntriesPerBook = 20

    private enum QueueResult {
        case queued  // Successfully added to queue
        case replacedOlder  // Replaced an older entry in queue
        case skippedNoChange  // Same timestamp as server/queue - nothing to do
        case skippedQueueHasNewer  // Queue already has newer entry
        case rejectedServerHasNewer  // Server position is newer than incoming
    }

    private var pendingProgressQueue: [PendingProgressSync] = []
    /// Latest known server position for each book. Updated when LMA loads metadata from server/disk,
    /// or when we successfully sync a position to the server.
    private var serverPositions: [String: BookReadingPosition] = [:]
    private var lastWakeTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var queueLoaded = false
    private var historyLoaded = false

    private var syncHistory: [String: [SyncHistoryEntry]] = [:]

    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var syncNotificationCallback: (@Sendable @MainActor (Int, [String]) -> Void)?

    private var incomingPositionObservers:
        [UUID: (bookId: String, callback: @Sendable @MainActor (IncomingServerPosition) -> Void)] =
            [:]
    private var pollingTask: Task<Void, Never>? = nil

    public init() {
        Task {
            await SilveranMigrations.ensureMigrationsRan()
            await loadQueueFromDisk()
            await loadHistoryFromDisk()
            await startPolling()
        }
    }

    private func ensureQueueLoaded() async {
        await SilveranMigrations.ensureMigrationsRan()
        guard !queueLoaded else { return }
        await loadQueueFromDisk()
    }

    private func ensureHistoryLoaded() async {
        await SilveranMigrations.ensureMigrationsRan()
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
        sourceID: BookSourceID? = nil,
        locator: BookLocator,
        timestamp: Double,
        reason: SyncReason,
        sourceIdentifier: String = "Unknown",
        locationDescription: String = "",
    ) async -> SyncResult {
        debugLog(
            "[PSA] syncProgress: bookId=\(bookId), reason=\(reason.rawValue), timestamp=\(timestamp), source=\(sourceIdentifier)"
        )

        let locatorSummary = buildLocatorSummary(locator)

        let queueResult = await queueOfflineProgress(
            bookId: bookId,
            sourceID: sourceID,
            locator: locator,
            timestamp: timestamp,
            syncedToStoryteller: false,
        )

        switch queueResult {
            case .rejectedServerHasNewer:
                let serverTs = serverPositions[bookId]?.timestamp ?? 0
                let rejectionNote = "rejected: server has newer (\(serverTs) > \(timestamp))"
                await addHistoryEntry(
                    bookId: bookId,
                    timestamp: timestamp,
                    sourceIdentifier: sourceIdentifier,
                    locationDescription: locationDescription,
                    reason: reason,
                    result: .rejectedAsOlder,
                    locatorSummary: "\(locatorSummary)\n\(rejectionNote)",
                    locator: locator,
                )
                debugLog("[PSA] syncProgress: rejected as older than server")
                return .success

            case .skippedNoChange, .skippedQueueHasNewer:
                return .success

            case .queued, .replacedOlder:
                break
        }

        await updateLocalMetadataProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
        )

        await addHistoryEntry(
            bookId: bookId,
            timestamp: timestamp,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
            reason: reason,
            result: .queued,
            locatorSummary: locatorSummary,
            locator: locator,
        )

        let sourceStatus = await BookServiceActor.shared.connectionStatus(sourceID: sourceID)
        debugLog("[PSA] syncProgress: sourceStatus=\(sourceStatus), sourceID=\(sourceID ?? "nil")")

        if sourceStatus == .connected, let sourceID {
            let result = await BookServiceActor.shared.sendProgressToServer(
                bookId: bookId,
                sourceID: sourceID,
                locator: locator,
                timestamp: timestamp,
            )
            if result == .success {
                debugLog("[PSA] syncProgress: synced to server")
                await markQueueItemSynced(bookId: bookId)
                updateServerPositionIfNewer(bookId: bookId, locator: locator, timestamp: timestamp)
                await updateHistoryResult(
                    bookId: bookId,
                    timestamp: timestamp,
                    result: .sent,
                )
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
        await ensureQueueLoaded()
        debugLog("[PSA] syncPendingQueue: starting with \(pendingProgressQueue.count) items")

        guard !pendingProgressQueue.isEmpty else {
            debugLog("[PSA] syncPendingQueue: queue empty")
            return (0, 0)
        }

        var syncedCount = 0
        var failedBookIds: [String] = []

        let queueSnapshot = pendingProgressQueue
        for var pending in queueSnapshot {
            if !pending.syncedToStoryteller {
                let sourceStatus = await BookServiceActor.shared.connectionStatus(
                    sourceID: pending.sourceID
                )
                guard sourceStatus == .connected else {
                    debugLog(
                        "[PSA] syncPendingQueue: source not connected, skipping \(pending.bookId), sourceID=\(pending.sourceID ?? "nil")"
                    )
                    continue
                }

                debugLog("[PSA] syncPendingQueue: sending \(pending.bookId)")
                guard let sourceID = pending.sourceID else {
                    debugLog("[PSA] syncPendingQueue: missing sourceID for \(pending.bookId)")
                    continue
                }
                let result = await BookServiceActor.shared.sendProgressToServer(
                    bookId: pending.bookId,
                    sourceID: sourceID,
                    locator: pending.locator,
                    timestamp: pending.timestamp,
                )
                if result == .success {
                    pending.syncedToStoryteller = true
                    updateServerPositionIfNewer(
                        bookId: pending.bookId,
                        locator: pending.locator,
                        timestamp: pending.timestamp,
                    )
                    await updateQueueItem(pending)
                    syncedCount += 1

                    await updateHistoryResult(
                        bookId: pending.bookId,
                        timestamp: pending.timestamp,
                        result: .sent,
                    )
                    debugLog("[PSA] syncPendingQueue: \(pending.bookId) sent successfully")
                } else if result == .failure {
                    debugLog("[PSA] syncPendingQueue: \(pending.bookId) failed permanently")
                    failedBookIds.append(pending.bookId)
                }
            }
        }

        let failedCount = failedBookIds.count
        debugLog("[PSA] syncPendingQueue: complete - sent=\(syncedCount), failed=\(failedCount)")

        if syncedCount > 0 || failedCount > 0 {
            await notifyObservers()
            await syncNotificationCallback?(syncedCount, failedBookIds)
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

    public func removePendingSync(for bookId: String) async {
        await ensureQueueLoaded()
        await removeFromQueue(bookId: bookId)
        await notifyObservers()
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

            if let pendingIndex = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }),
                abs(pendingProgressQueue[pendingIndex].timestamp - incomingTimestamp) < 1.0
            {
                let pendingTimestamp = pendingProgressQueue[pendingIndex].timestamp
                pendingProgressQueue.remove(at: pendingIndex)
                serverPositions[bookId] = incomingPosition
                await saveQueueToDisk()

                await updateHistoryResult(
                    bookId: bookId,
                    timestamp: pendingTimestamp,
                    result: .completed,
                )
                reconciledCount += 1
                continue
            }

            if let existing = serverPositions[bookId], let existingTs = existing.timestamp {
                if abs(existingTs - incomingTimestamp) < 1.0 {
                    continue
                }
            }

            let locatorSummary =
                incomingPosition.locator.map { buildLocatorSummary($0) } ?? "no locator"
            let locationDesc = buildLocationDescription(from: incomingPosition.locator)

            if let pendingIndex = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
                let pending = pendingProgressQueue[pendingIndex]
                if incomingTimestamp > pending.timestamp {
                    debugLog(
                        "[PSA] updateServerPositions: server newer for \(bookId), removing pending (server: \(incomingTimestamp), pending: \(pending.timestamp))"
                    )
                    pendingProgressQueue.remove(at: pendingIndex)
                    serverPositions[bookId] = incomingPosition
                    reconciledCount += 1
                    updatedCount += 1

                    await updateHistoryResult(
                        bookId: bookId,
                        timestamp: pending.timestamp,
                        result: .completed,
                    )

                    await addHistoryEntry(
                        bookId: bookId,
                        timestamp: incomingTimestamp,
                        sourceIdentifier: "Server",
                        locationDescription: locationDesc,
                        reason: .connectionRestored,
                        result: .serverIncomingAccepted,
                        locatorSummary: locatorSummary,
                        locator: incomingPosition.locator,
                    )

                    if let locator = incomingPosition.locator {
                        await notifyIncomingPositionObservers(
                            bookId: bookId,
                            locator: locator,
                            timestamp: incomingTimestamp,
                        )
                    }
                } else {
                    debugLog(
                        "[PSA] updateServerPositions: pending newer for \(bookId), keeping pending (server: \(incomingTimestamp), pending: \(pending.timestamp))"
                    )

                    await addHistoryEntry(
                        bookId: bookId,
                        timestamp: incomingTimestamp,
                        sourceIdentifier: "Server",
                        locationDescription: locationDesc,
                        reason: .connectionRestored,
                        result: .serverIncomingRejected,
                        locatorSummary:
                            "rejected: pending is newer (\(pending.timestamp) > \(incomingTimestamp))",
                        locator: incomingPosition.locator,
                    )
                }
            } else {
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
                            locatorSummary: locatorSummary,
                            locator: incomingPosition.locator,
                        )

                        if let locator = incomingPosition.locator {
                            await notifyIncomingPositionObservers(
                                bookId: bookId,
                                locator: locator,
                                timestamp: incomingTimestamp,
                            )
                        }
                    }
                } else {
                    serverPositions[bookId] = incomingPosition
                    updatedCount += 1
                }
            }
        }

        if reconciledCount > 0 {
            await saveQueueToDisk()
        }

        if updatedCount > 0 || reconciledCount > 0 {
            debugLogVerbose(
                "[PSA] updateServerPositions: updated \(updatedCount), reconciled \(reconciledCount), total=\(serverPositions.count)"
            )
        }
    }

    private func buildLocationDescription(from locator: BookLocator?) -> String {
        guard let locator = locator else { return "" }
        if let title = locator.title {
            if let prog = locator.locations?.totalProgression {
                return "\(title), \(Int(prog * 100))%"
            }
            return title
        }
        return "Unknown Chapter"
    }

    /// Get reconciled progress for all books (pending queue takes precedence over server)
    public func getAllBookProgress() async -> [String: BookProgress] {
        await ensureQueueLoaded()

        var result: [String: BookProgress] = [:]

        for (bookId, serverPosition) in serverPositions {
            if let pending = pendingProgressQueue.first(where: { $0.bookId == bookId }) {
                result[bookId] = BookProgress(
                    locator: pending.locator,
                    timestamp: pending.timestamp,
                    source: .pendingSync,
                )
            } else {
                result[bookId] = BookProgress(
                    locator: serverPosition.locator,
                    timestamp: serverPosition.timestamp,
                    source: .server,
                )
            }
        }

        for pending in pendingProgressQueue where result[pending.bookId] == nil {
            result[pending.bookId] = BookProgress(
                locator: pending.locator,
                timestamp: pending.timestamp,
                source: .pendingSync,
            )
        }

        return result
    }

    /// Get reconciled progress for a single book
    public func getBookProgress(for bookId: String) async -> BookProgress? {
        await ensureQueueLoaded()

        if let pending = pendingProgressQueue.first(where: { $0.bookId == bookId }) {
            return BookProgress(
                locator: pending.locator,
                timestamp: pending.timestamp,
                source: .pendingSync,
            )
        }

        if let serverPosition = serverPositions[bookId] {
            return BookProgress(
                locator: serverPosition.locator,
                timestamp: serverPosition.timestamp,
                source: .server,
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
        _ callback: @escaping @Sendable @MainActor (Int, [String]) -> Void
    ) {
        syncNotificationCallback = callback
    }

    // MARK: - Incoming Position Observers

    @discardableResult
    public func addIncomingPositionObserver(
        for bookId: String,
        _ callback: @escaping @Sendable @MainActor (IncomingServerPosition) -> Void,
    ) -> UUID {
        let id = UUID()
        incomingPositionObservers[id] = (bookId: bookId, callback: callback)
        debugLog(
            "[PSA] addIncomingPositionObserver: id=\(id), bookId=\(bookId), total=\(incomingPositionObservers.count)"
        )
        return id
    }

    public func removeIncomingPositionObserver(id: UUID) {
        incomingPositionObservers.removeValue(forKey: id)
        debugLog(
            "[PSA] removeIncomingPositionObserver: id=\(id), total=\(incomingPositionObservers.count)"
        )
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        debugLog("[PSA] startPolling: starting continuous polling task")
        pollingTask = Task {
            await SilveranMigrations.ensureMigrationsRan()
            while !Task.isCancelled {
                await pollServerPositions()
                let hasConnectedSource = await BookServiceActor.shared.hasConnectedSource()
                let sleepInterval: Duration =
                    hasConnectedSource
                    ? .seconds(3)
                    : .seconds(15)
                try? await Task.sleep(for: sleepInterval)
            }
            pollingTask = nil
            debugLog("[PSA] polling task ended")
        }
    }

    public func stopPolling() {
        debugLog("[PSA] stopPolling: stopping polling task")
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollServerPositions() async {
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
        let sourceMetadata = snapshot.books
        let allPaths = snapshot.mediaPaths
        let downloadedBookIds = Set(
            allPaths.filter { _, paths in
                paths.ebookPath != nil || paths.audioPath != nil || paths.syncedPath != nil
            }.keys
        )
        guard !downloadedBookIds.isEmpty else { return }

        let metadataByID = Dictionary(
            uniqueKeysWithValues: sourceMetadata.map { ($0.uuid, $0) }
        )

        for bookId in downloadedBookIds {
            guard let sourceID = metadataByID[bookId]?.sourceID else { continue }
            if let position = await BookServiceActor.shared.fetchBookPosition(
                bookId: bookId,
                sourceID: sourceID,
            ) {
                await updateServerPositions([bookId: position])
            }
        }
    }

    private func notifyIncomingPositionObservers(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async {
        let position = IncomingServerPosition(
            locator: locator,
            timestamp: timestamp,
        )
        for (_, observer) in incomingPositionObservers where observer.bookId == bookId {
            await observer.callback(position)
        }
        debugLogVerbose(
            "[PSA] notifyIncomingPositionObservers: notified observers for bookId=\(bookId)"
        )
    }

    // MARK: - Private Helpers

    private func updateServerPositionIfNewer(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) {
        if let existing = serverPositions[bookId], let existingTimestamp = existing.timestamp {
            if timestamp <= existingTimestamp {
                debugLog(
                    "[PSA] updateServerPositionIfNewer: existing is newer, skipping (incoming: \(timestamp), existing: \(existingTimestamp))"
                )
                return
            }
        }

        let updatedAtString = Date(timeIntervalSince1970: timestamp / 1000).ISO8601Format()
        serverPositions[bookId] = BookReadingPosition(
            uuid: serverPositions[bookId]?.uuid,
            locator: locator,
            timestamp: timestamp,
            createdAt: serverPositions[bookId]?.createdAt,
            updatedAt: updatedAtString,
        )
        debugLog("[PSA] updateServerPositionIfNewer: bookId=\(bookId), timestamp=\(timestamp)")
    }

    private func queueOfflineProgress(
        bookId: String,
        sourceID: BookSourceID?,
        locator: BookLocator,
        timestamp: Double,
        syncedToStoryteller: Bool = false,
    ) async -> QueueResult {
        await ensureQueueLoaded()

        if let serverPosition = serverPositions[bookId],
            let serverTimestamp = serverPosition.timestamp
        {
            if timestamp == serverTimestamp {
                debugLog(
                    "[PSA] queueOfflineProgress: same as server, no change (timestamp: \(timestamp))"
                )
                return .skippedNoChange
            }
            if timestamp < serverTimestamp {
                debugLog(
                    "[PSA] queueOfflineProgress: server has newer, rejecting (incoming: \(timestamp), server: \(serverTimestamp))"
                )
                return .rejectedServerHasNewer
            }
        }

        if let existingIndex = pendingProgressQueue.firstIndex(where: { $0.bookId == bookId }) {
            let existing = pendingProgressQueue[existingIndex]
            if timestamp == existing.timestamp {
                debugLog(
                    "[PSA] queueOfflineProgress: same as queue, no change (timestamp: \(timestamp))"
                )
                return .skippedNoChange
            }
            if timestamp < existing.timestamp {
                debugLog(
                    "[PSA] queueOfflineProgress: queue has newer, skipping (incoming: \(timestamp), existing: \(existing.timestamp))"
                )
                return .skippedQueueHasNewer
            }
            pendingProgressQueue.remove(at: existingIndex)

            let pending = PendingProgressSync(
                bookId: bookId,
                sourceID: sourceID,
                locator: locator,
                timestamp: timestamp,
                syncedToStoryteller: syncedToStoryteller,
            )
            pendingProgressQueue.append(pending)

            debugLog(
                "[PSA] queueOfflineProgress: replaced older entry, bookId=\(bookId), queueSize=\(pendingProgressQueue.count)"
            )

            await saveQueueToDisk()
            await notifyObservers()
            return .replacedOlder
        }

        let pending = PendingProgressSync(
            bookId: bookId,
            sourceID: sourceID,
            locator: locator,
            timestamp: timestamp,
            syncedToStoryteller: syncedToStoryteller,
        )
        pendingProgressQueue.append(pending)

        debugLog(
            "[PSA] queueOfflineProgress: queued, bookId=\(bookId), queueSize=\(pendingProgressQueue.count)"
        )

        await saveQueueToDisk()
        await notifyObservers()
        return .queued
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
        timestamp: Double,
    ) async {
        await LocalMediaActor.shared.updateBookProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
        )
    }

    private func notifyObservers() async {
        debugLogVerbose("[PSA] notifyObservers: notifying \(observers.count) observers")
        for (_, callback) in observers {
            await callback()
        }
    }

    // MARK: - Persistence

    private func loadQueueFromDisk() async {
        guard !queueLoaded else { return }
        do {
            let loaded = try await FilesystemActor.shared.loadProgressQueue()
            guard !queueLoaded else { return }
            pendingProgressQueue = loaded
            queueLoaded = true
            debugLog("[PSA] loadQueueFromDisk: loaded \(pendingProgressQueue.count) items")
        } catch {
            guard !queueLoaded else { return }
            debugLog("[PSA] loadQueueFromDisk: failed - \(error)")
            pendingProgressQueue = []
            queueLoaded = true
        }
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
        locatorSummary: String,
        locator: BookLocator? = nil,
    ) async {
        await ensureHistoryLoaded()

        let entry = SyncHistoryEntry(
            timestamp: timestamp,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
            reason: reason,
            result: result,
            locatorSummary: locatorSummary,
            locator: locator,
        )

        var entries = syncHistory[bookId] ?? []
        entries.append(entry)

        if entries.count > Self.maxHistoryEntriesPerBook {
            entries = Array(entries.suffix(Self.maxHistoryEntriesPerBook))
        }

        syncHistory[bookId] = entries
        await saveHistoryToDisk()
    }

    private func updateHistoryResult(
        bookId: String,
        timestamp: Double,
        result: SyncHistoryEntry.SyncHistoryResult,
    ) async {
        await ensureHistoryLoaded()

        guard var entries = syncHistory[bookId] else { return }

        if let index = entries.lastIndex(where: { $0.timestamp == timestamp }) {
            let existing = entries[index]
            entries[index] = SyncHistoryEntry(
                timestamp: existing.timestamp,
                sourceIdentifier: existing.sourceIdentifier,
                locationDescription: existing.locationDescription,
                reason: existing.reason,
                result: result,
                locatorSummary: existing.locatorSummary,
                locator: existing.locator,
            )
            syncHistory[bookId] = entries
            await saveHistoryToDisk()
        }
    }

    public func getSyncHistory(for bookId: String) async -> [SyncHistoryEntry] {
        await ensureHistoryLoaded()
        return syncHistory[bookId] ?? []
    }

    public func getAllSyncHistory() async -> [String: [SyncHistoryEntry]] {
        await ensureHistoryLoaded()
        return syncHistory
    }

    public func clearSyncHistory(for bookId: String) async {
        await ensureHistoryLoaded()
        syncHistory.removeValue(forKey: bookId)
        await saveHistoryToDisk()
    }

    public func restorePosition(
        bookId: String,
        sourceID: BookSourceID? = nil,
        locator: BookLocator,
        locationDescription: String,
    )
        async -> SyncResult
    {
        let timestamp = floor(Date().timeIntervalSince1970 * 1000)
        return await syncProgress(
            bookId: bookId,
            sourceID: sourceID,
            locator: locator,
            timestamp: timestamp,
            reason: .userRestoredFromHistory,
            sourceIdentifier: "Restored from History",
            locationDescription: locationDescription,
        )
    }

    private func loadHistoryFromDisk() async {
        guard !historyLoaded else { return }
        do {
            let loaded = try await FilesystemActor.shared.loadSyncHistory()
            guard !historyLoaded else { return }
            syncHistory = loaded
            historyLoaded = true
        } catch {
            guard !historyLoaded else { return }
            syncHistory = [:]
            historyLoaded = true
        }
    }

    private func saveHistoryToDisk() async {
        do {
            try await FilesystemActor.shared.saveSyncHistory(syncHistory)
        } catch {
            debugLog("[PSA] saveHistoryToDisk: failed - \(error)")
        }
    }
}
