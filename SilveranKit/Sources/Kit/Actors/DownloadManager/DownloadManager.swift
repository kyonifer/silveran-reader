import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor DownloadManager {
    public static let shared = DownloadManager()

    private static let maxAutoRetries = 3
    private static let retryBaseDelay: TimeInterval = 30

    private let delegate = DownloadManagerDelegate()
    private lazy var downloadSession: URLSession = {
        let identifier: String
        #if os(watchOS)
        identifier = "com.kyonifer.silveran.watch.downloads"
        #else
        identifier = "com.kyonifer.silveran.downloads"
        #endif

        #if !canImport(Darwin)
        let config = URLSessionConfiguration.default
        #else
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        #endif
        #if canImport(Darwin)
        config.waitsForConnectivity = true
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        #endif
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600

        #if os(watchOS)
        config.isDiscretionary = false
        #endif

        return URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil,
        )
    }()

    private var downloads: [String: DownloadRecord] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var bookMetadataCache: [String: BookMetadata] = [:]
    private var observers: [UUID: @Sendable @MainActor ([DownloadRecord]) -> Void] = [:]
    private var backgroundCompletionHandler: (@Sendable () -> Void)?
    private var initialized = false
    private var retryLoopRunning = false

    private init() {}

    // MARK: - Initialization

    private func ensureInitialized() async {
        guard !initialized else { return }
        initialized = true

        let persisted = await loadPersistedState()
        for record in persisted {
            downloads[record.id] = record
        }

        await reconnectOutstandingTasks()
        startRetryLoop()
    }

    private func reconnectOutstandingTasks() async {
        let tasks = await withCheckedContinuation {
            (continuation: CheckedContinuation<[URLSessionDownloadTask], Never>) in
            downloadSession.getTasksWithCompletionHandler { _, _, downloadTasks in
                continuation.resume(returning: downloadTasks)
            }
        }

        for task in tasks {
            guard let downloadId = task.taskDescription else {
                task.cancel()
                continue
            }

            if let record = downloads[downloadId] {
                activeTasks[downloadId] = task
                delegate.registerTask(task, downloadId: downloadId)

                var updated = record
                updated.state = .downloading(progress: record.progressFraction)
                updated.lastUpdatedAt = Date()
                downloads[downloadId] = updated
            } else {
                task.cancel()
            }
        }

        for (id, record) in downloads {
            if record.isActive && activeTasks[id] == nil {
                var updated = record
                let hasResume = await hasResumeData(for: id)
                updated.state = .paused(hasResumeData: hasResume)
                updated.lastUpdatedAt = Date()
                downloads[id] = updated
            }
        }

        await persistState()
        notifyObservers()
    }

    private func startRetryLoop() {
        guard !retryLoopRunning else { return }
        retryLoopRunning = true

        Task { [weak self = self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { break }
                await self.retryIncompleteDownloads()
            }
        }
    }

    private func retryIncompleteDownloads() async {
        let now = Date()
        var stalled: [DownloadRecord] = []

        for record in downloads.values where !record.isActive && record.isIncomplete {
            if case .failed = record.state {
                guard record.retryCount < Self.maxAutoRetries else { continue }

                let backoff = Self.retryBaseDelay * pow(2.0, Double(record.retryCount))
                guard now.timeIntervalSince(record.lastUpdatedAt) >= backoff else { continue }

                var updated = record
                updated.retryCount += 1
                downloads[record.id] = updated
                stalled.append(updated)
            } else {
                stalled.append(record)
            }
        }

        guard !stalled.isEmpty else { return }

        debugLog("[DownloadManager] Retry loop: resuming \(stalled.count) stalled download(s)")
        for record in stalled {
            await performResume(downloadId: record.id)
        }
    }

    // MARK: - Public Operations

    public func startDownload(for book: BookMetadata, category: LocalMediaCategory) async {
        await ensureInitialized()

        let id = "\(book.id)-\(category.rawValue)"

        if let existing = downloads[id] {
            if existing.isActive {
                debugLog("[DownloadManager] Download already active: \(id)")
                return
            }
            bookMetadataCache[book.id] = book
            await resumeDownload(for: book.id, category: category)
            return
        }

        let format = formatForCategory(category, book: book)
        guard let format else {
            debugLog("[DownloadManager] No available format for \(book.title) / \(category)")
            return
        }
        guard let sourceID = book.sourceID else {
            debugLog("[DownloadManager] Cannot download \(book.title): missing source ID")
            return
        }

        let record = DownloadRecord(
            bookId: book.id,
            sourceID: sourceID,
            category: category,
            bookTitle: book.title,
            format: format,
        )

        downloads[record.id] = record
        bookMetadataCache[book.id] = book

        await beginDownloadTask(for: record, book: book)
    }

    public func pauseDownload(for bookId: String, category: LocalMediaCategory) async {
        await ensureInitialized()

        let id = "\(bookId)-\(category.rawValue)"
        guard let task = activeTasks.removeValue(forKey: id) else { return }

        let resumeData = await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            task.cancel { data in
                continuation.resume(returning: data)
            }
        }

        if let resumeData {
            await saveResumeData(resumeData, for: id)
        }

        if var record = downloads[id] {
            record.state = .paused(hasResumeData: resumeData != nil)
            record.lastUpdatedAt = Date()
            downloads[id] = record
        }

        await persistState()
        notifyObservers()
    }

    public func resumeDownload(for bookId: String, category: LocalMediaCategory) async {
        await ensureInitialized()

        let id = "\(bookId)-\(category.rawValue)"
        guard var record = downloads[id] else { return }

        // A manual resume restores the auto-retry budget.
        record.retryCount = 0
        downloads[id] = record

        await performResume(downloadId: id)
    }

    private func performResume(downloadId id: String) async {
        guard var record = downloads[id] else { return }
        let bookId = record.bookId

        if record.isActive && activeTasks[id] != nil {
            debugLog("[DownloadManager] Download already active, skipping resume: \(id)")
            return
        }

        let hasResume = await hasResumeData(for: id)

        var book = bookMetadataCache[bookId]
        if book == nil && !hasResume {
            book = await BookServiceActor.shared.fetchBookDetails(
                for: bookId,
                sourceID: record.sourceID,
            )
        }

        if book == nil && !hasResume {
            debugLog(
                "[DownloadManager] Cannot resume: no metadata and no resume data for \(bookId)"
            )
            return
        }

        if let book {
            bookMetadataCache[bookId] = book
        }

        record.state = .queued
        record.lastUpdatedAt = Date()
        downloads[id] = record
        notifyObservers()

        await beginDownloadTask(for: record, book: book)
    }

    public func cancelDownload(for bookId: String, category: LocalMediaCategory) async {
        await ensureInitialized()

        let id = "\(bookId)-\(category.rawValue)"

        if let task = activeTasks.removeValue(forKey: id) {
            task.cancel()
        }

        downloads.removeValue(forKey: id)
        await deleteResumeData(for: id)

        await persistState()
        notifyObservers()
    }

    // MARK: - State Access

    public var incompleteDownloads: [DownloadRecord] {
        get async {
            await ensureInitialized()
            return downloads.values
                .filter { $0.isIncomplete }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func downloadState(for bookId: String, category: LocalMediaCategory) async
        -> DownloadRecord?
    {
        await ensureInitialized()
        let id = "\(bookId)-\(category.rawValue)"
        return downloads[id]
    }

    public func downloadProgress(for bookId: String, category: LocalMediaCategory) async -> Double?
    {
        await ensureInitialized()
        let id = "\(bookId)-\(category.rawValue)"
        guard let record = downloads[id], record.isActive else { return nil }
        return record.progressFraction
    }

    // MARK: - Observation

    // Ensures the retry loop starts on boot: called from MediaViewModel.init on iOS/macOS/tvOS,
    // and from SilveranWatchApp.task on watchOS.
    public func addObserver(_ callback: @escaping @Sendable @MainActor ([DownloadRecord]) -> Void)
        async -> UUID
    {
        await ensureInitialized()
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        let snapshot = Array(downloads.values)
        let callbacks = Array(observers.values)
        Task { @MainActor in
            for callback in callbacks {
                callback(snapshot)
            }
        }
    }

    // MARK: - Background Session

    public func handleBackgroundSessionEvents(completionHandler: @escaping @Sendable () -> Void)
        async
    {
        await ensureInitialized()
        backgroundCompletionHandler = completionHandler
    }

    func handleBackgroundSessionFinished() {
        if let handler = backgroundCompletionHandler {
            backgroundCompletionHandler = nil
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    // MARK: - Delegate Callbacks

    func handleProgress(
        downloadId: String,
        receivedBytes: Int64,
        expectedBytes: Int64?,
        progress: Double,
    ) {
        guard var record = downloads[downloadId] else { return }
        record.state = .downloading(progress: progress)
        record.receivedBytes = receivedBytes
        if let expectedBytes {
            record.expectedBytes = expectedBytes
        }
        record.lastUpdatedAt = Date()
        downloads[downloadId] = record
        notifyObservers()
    }

    func handleFileDownloaded(downloadId: String, tempURL: URL) async {
        guard var record = downloads[downloadId] else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        record.state = .importing
        record.lastUpdatedAt = Date()
        downloads[downloadId] = record
        notifyObservers()

        var book = bookMetadataCache[record.bookId]
        if book == nil {
            book = await BookServiceActor.shared.fetchBookDetails(
                for: record.bookId,
                sourceID: record.sourceID,
            )
        }

        guard let book else {
            debugLog("[DownloadManager] No metadata for import: \(record.bookId)")
            record.state = .failed(error: "Missing book metadata", hasResumeData: false)
            record.lastUpdatedAt = Date()
            downloads[downloadId] = record
            await persistState()
            notifyObservers()
            return
        }

        let filename = fallbackFilename(bookId: record.bookId, format: record.format)

        do {
            try await LocalMediaActor.shared.importDownloadedFile(
                from: tempURL,
                metadata: book,
                category: record.category,
                filename: filename,
            )

            record.state = .completed
            record.lastUpdatedAt = Date()
            if let expected = record.expectedBytes {
                record.receivedBytes = expected
            }
            downloads[downloadId] = record

            downloads.removeValue(forKey: downloadId)
            await deleteResumeData(for: downloadId)
        } catch {
            debugLog("[DownloadManager] Import failed for \(record.bookTitle): \(error)")
            record.state = .failed(error: error.localizedDescription, hasResumeData: false)
            // The file downloaded fine, so the import error will recur on every attempt.
            // Exhaust the auto-retry budget; the user can still retry manually.
            record.retryCount = Self.maxAutoRetries
            record.lastUpdatedAt = Date()
            downloads[downloadId] = record
        }

        await persistState()
        notifyObservers()
    }

    func handleFailure(downloadId: String, error: Error, resumeData: Data?) async {
        guard var record = downloads[downloadId] else { return }

        activeTasks.removeValue(forKey: downloadId)

        if let resumeData {
            await saveResumeData(resumeData, for: downloadId)
        }

        var hasResume = resumeData != nil
        if !hasResume {
            hasResume = await hasResumeData(for: downloadId)
        }

        // System-cancelled downloads (-999) are interruptions, not real failures
        if let urlError = error as? URLError, urlError.code == .cancelled {
            record.state = .paused(hasResumeData: hasResume)
        } else {
            record.state = .failed(error: error.localizedDescription, hasResumeData: hasResume)
        }

        record.lastUpdatedAt = Date()
        downloads[downloadId] = record

        await persistState()
        notifyObservers()
    }

    func handleHTTPError(downloadId: String, statusCode: Int) async {
        guard var record = downloads[downloadId] else { return }

        activeTasks.removeValue(forKey: downloadId)
        await deleteResumeData(for: downloadId)

        if statusCode == 401 || statusCode == 403 {
            debugLog(
                "[DownloadManager] Auth expired for \(record.bookTitle), retrying with fresh credentials"
            )

            var book = bookMetadataCache[record.bookId]
            if book == nil {
                book = await BookServiceActor.shared.fetchBookDetails(
                    for: record.bookId,
                    sourceID: record.sourceID,
                )
            }

            if let book {
                bookMetadataCache[record.bookId] = book
                record.state = .queued
                record.lastUpdatedAt = Date()
                downloads[downloadId] = record
                notifyObservers()
                await beginDownloadTask(for: record, book: book)
                return
            }
        }

        record.state = .failed(error: "Server error (\(statusCode))", hasResumeData: false)
        record.lastUpdatedAt = Date()
        downloads[downloadId] = record
        await persistState()
        notifyObservers()
    }

    // MARK: - Private Helpers

    private func beginDownloadTask(for record: DownloadRecord, book: BookMetadata?) async {
        if let existingTask = activeTasks.removeValue(forKey: record.id) {
            existingTask.cancel()
        }

        let sourceRecords = await BookServiceActor.shared.bookSources
        let sourceRecord = sourceRecords.first {
            $0.id == record.sourceID
        }

        if sourceRecord?.kind == .localFolder {
            await resolveFolderSourceMedia(for: record)
            return
        }

        let resumeData = await loadResumeData(for: record.id)
        let task: URLSessionDownloadTask

        if let resumeData {
            task = downloadSession.downloadTask(withResumeData: resumeData)
            await deleteResumeData(for: record.id)
        } else {
            guard book != nil else {
                debugLog(
                    "[DownloadManager] Cannot start download: no metadata for \(record.bookTitle)"
                )
                var updated = record
                updated.state = .failed(error: "Missing book metadata", hasResumeData: false)
                updated.lastUpdatedAt = Date()
                downloads[record.id] = updated
                await persistState()
                notifyObservers()
                return
            }

            guard
                let request = await BookServiceActor.shared.createAuthenticatedDownloadRequest(
                    for: record.bookId,
                    sourceID: record.sourceID,
                    format: record.format,
                )
            else {
                debugLog("[DownloadManager] Failed to create request for \(record.bookTitle)")
                var updated = record
                updated.state = .failed(error: "Authentication failed", hasResumeData: false)
                updated.lastUpdatedAt = Date()
                downloads[record.id] = updated
                await persistState()
                notifyObservers()
                return
            }

            task = downloadSession.downloadTask(with: request)
        }

        task.taskDescription = record.id
        delegate.registerTask(task, downloadId: record.id)
        activeTasks[record.id] = task

        var updated = record
        updated.state = .downloading(progress: updated.progressFraction)
        updated.lastUpdatedAt = Date()
        downloads[record.id] = updated

        task.resume()

        await persistState()
        notifyObservers()
    }

    private func resolveFolderSourceMedia(for record: DownloadRecord) async {
        var importing = record
        importing.state = .importing
        importing.lastUpdatedAt = Date()
        downloads[record.id] = importing
        notifyObservers()

        if await BookServiceActor.shared.resolveLocalMedia(
            for: record.bookId,
            sourceID: record.sourceID,
            category: record.category,
        ) != nil {
            downloads.removeValue(forKey: record.id)
            await deleteResumeData(for: record.id)
        } else {
            debugLog(
                "[DownloadManager] Folder source media unavailable for \(record.bookTitle) / \(record.category.rawValue)"
            )
            var failed = record
            failed.state = .failed(error: "Source media is unavailable", hasResumeData: false)
            failed.lastUpdatedAt = Date()
            downloads[record.id] = failed
        }

        await persistState()
        notifyObservers()
    }

    private func formatForCategory(_ category: LocalMediaCategory, book: BookMetadata)
        -> StorytellerBookFormat?
    {
        switch category {
            case .ebook:
                return book.hasAvailableEbook ? .ebook : nil
            case .audio:
                return book.hasAvailableAudiobook ? .audiobook : nil
            case .synced:
                return book.hasAvailableReadaloud ? .readaloud : nil
        }
    }

    private func fallbackFilename(bookId: String, format: StorytellerBookFormat) -> String {
        let ext: String =
            switch format {
                case .ebook, .readaloud: "epub"
                case .audiobook: "audiobook"
            }
        return "\(bookId).\(ext)"
    }

    // MARK: - Persistence

    private func persistState() async {
        let records = Array(downloads.values)
        do {
            try await FilesystemActor.shared.saveDownloadState(records)
        } catch {
            debugLog("[DownloadManager] Failed to persist state: \(error)")
        }
    }

    private func loadPersistedState() async -> [DownloadRecord] {
        do {
            return try await FilesystemActor.shared.loadDownloadState()
        } catch {
            debugLog("[DownloadManager] Failed to load persisted state: \(error)")
            return []
        }
    }

    private func saveResumeData(_ data: Data, for id: String) async {
        do {
            try await FilesystemActor.shared.saveResumeData(data, for: id)
        } catch {
            debugLog("[DownloadManager] Failed to save resume data: \(error)")
        }
    }

    private func loadResumeData(for id: String) async -> Data? {
        do {
            return try await FilesystemActor.shared.loadResumeData(for: id)
        } catch {
            return nil
        }
    }

    private func hasResumeData(for id: String) async -> Bool {
        await FilesystemActor.shared.hasResumeData(for: id)
    }

    private func deleteResumeData(for id: String) async {
        do {
            try await FilesystemActor.shared.deleteResumeData(for: id)
        } catch {
            debugLog("[DownloadManager] Failed to delete resume data: \(error)")
        }
    }
}
