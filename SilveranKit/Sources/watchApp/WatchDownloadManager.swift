#if os(watchOS)
import Foundation
import SilveranKitCommon

public actor WatchDownloadManager {
    public static let shared = WatchDownloadManager()

    private var backgroundSession: URLSession
    private var activeDownloads: [String: DownloadInfo] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]
    private var bytesHandlers: [String: @Sendable (Int64, Int64) -> Void] = [:]
    private var completionHandlers: [String: @Sendable (Bool) -> Void] = [:]

    private struct DownloadInfo {
        let metadata: BookMetadata
        let category: LocalMediaCategory
    }

    private init() {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.kyonifer.silveran.watch.downloads"
        )
        config.waitsForConnectivity = true
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600

        let session = URLSession(
            configuration: config,
            delegate: WatchDownloadDelegate.shared,
            delegateQueue: nil
        )
        backgroundSession = session

        session.getAllTasks { tasks in
            for task in tasks {
                debugLog("[WatchDownloadManager] Cancelling stale task: \(task.taskDescription ?? "unknown")")
                task.cancel()
            }
        }

        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsURL = docsDir.appendingPathComponent("active_downloads.json")
        try? FileManager.default.removeItem(at: downloadsURL)

        let tempDir = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
            for file in files where file.hasSuffix("_download.epub") {
                let fileURL = tempDir.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fileURL)
                debugLog("[WatchDownloadManager] Removed stale temp file: \(file)")
            }
        }

        debugLog("[WatchDownloadManager] Cleared persisted downloads and temp files")
    }

    public func downloadBook(
        _ book: BookMetadata,
        progressHandler: @escaping @Sendable (Double) -> Void,
        bytesHandler: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async {
        let formatString = book.hasAvailableReadaloud ? "readaloud" : "ebook"
        let category: LocalMediaCategory = book.hasAvailableReadaloud ? .synced : .ebook

        if let existingTask = activeTasks[book.uuid] {
            debugLog("[WatchDownloadManager] Cancelling existing task for: \(book.title)")
            existingTask.cancel()
            activeTasks.removeValue(forKey: book.uuid)
        }

        progressHandlers[book.uuid] = progressHandler
        if let bytesHandler {
            bytesHandlers[book.uuid] = bytesHandler
        }
        progressHandler(0)

        guard let (baseURL, token) = await getAuthInfo() else {
            debugLog("[WatchDownloadManager] No auth info available")
            return
        }

        let downloadURL = baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(book.uuid)
            .appendingPathComponent("files")

        guard var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false) else {
            debugLog("[WatchDownloadManager] Failed to create URL components")
            return
        }
        components.queryItems = [URLQueryItem(name: "format", value: formatString)]

        guard let requestURL = components.url else {
            debugLog("[WatchDownloadManager] Failed to create request URL")
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let downloadInfo = DownloadInfo(metadata: book, category: category)
        activeDownloads[book.uuid] = downloadInfo

        WatchDownloadDelegate.shared.registerDownload(
            bookId: book.uuid,
            title: book.title,
            category: category.rawValue
        )

        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = book.uuid
        activeTasks[book.uuid] = task
        task.resume()

        debugLog("[WatchDownloadManager] Started download for: \(book.title)")

        await waitForDownloadCompletion(bookId: book.uuid)
    }

    public func cancelDownload(bookId: String) {
        debugLog("[WatchDownloadManager] Cancelling download: \(bookId)")

        if let task = activeTasks[bookId] {
            task.cancel()
        }

        activeTasks.removeValue(forKey: bookId)
        activeDownloads.removeValue(forKey: bookId)
        progressHandlers.removeValue(forKey: bookId)
        bytesHandlers.removeValue(forKey: bookId)

        if let handler = completionHandlers.removeValue(forKey: bookId) {
            handler(false)
        }
    }

    public func isDownloading(bookId: String) -> Bool {
        return activeTasks[bookId] != nil
    }

    private func waitForDownloadCompletion(bookId: String) async {
        await withCheckedContinuation { continuation in
            completionHandlers[bookId] = { _ in
                continuation.resume()
            }
        }
    }

    public func handleDownloadProgress(
        bookId: String,
        progress: Double,
        bytesWritten: Int64,
        totalBytes: Int64
    ) {
        Task {
            await updateProgress(
                bookId: bookId,
                progress: progress,
                bytesWritten: bytesWritten,
                totalBytes: totalBytes
            )
        }
    }

    private func updateProgress(
        bookId: String,
        progress: Double,
        bytesWritten: Int64,
        totalBytes: Int64
    ) {
        progressHandlers[bookId]?(progress)
        bytesHandlers[bookId]?(bytesWritten, totalBytes)
    }

    public func handleDownloadComplete(
        bookId: String,
        tempURL: URL,
        success: Bool
    ) {
        Task {
            await processDownloadComplete(bookId: bookId, tempURL: tempURL, success: success)
        }
    }

    private func processDownloadComplete(bookId: String, tempURL: URL, success: Bool) async {
        defer {
            activeTasks.removeValue(forKey: bookId)
            activeDownloads.removeValue(forKey: bookId)
            progressHandlers.removeValue(forKey: bookId)
            bytesHandlers.removeValue(forKey: bookId)

            if let handler = completionHandlers.removeValue(forKey: bookId) {
                handler(success)
            }
        }

        guard success else {
            debugLog("[WatchDownloadManager] Download failed for: \(bookId)")
            return
        }

        guard let downloadInfo = activeDownloads[bookId] else {
            debugLog("[WatchDownloadManager] No download info found for: \(bookId)")
            return
        }

        do {
            try await LocalMediaActor.shared.importDownloadedFile(
                from: tempURL,
                metadata: downloadInfo.metadata,
                category: downloadInfo.category,
                filename: "book.epub"
            )
            debugLog("[WatchDownloadManager] Saved book via LMA: \(downloadInfo.metadata.title)")
        } catch {
            debugLog("[WatchDownloadManager] Failed to save book: \(error)")
        }
    }

    private func getAuthInfo() async -> (URL, String)? {
        let apiURL = await StorytellerActor.shared.currentApiBaseURL
        let token = await StorytellerActor.shared.currentAccessToken

        guard let url = apiURL, let accessToken = token else {
            return nil
        }

        return (url, accessToken)
    }
}

final class WatchDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = WatchDownloadDelegate()

    private var downloadInfo: [String: (title: String, category: String)] = [:]

    func registerDownload(bookId: String, title: String, category: String) {
        downloadInfo[bookId] = (title, category)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let bookId = downloadTask.taskDescription else { return }

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }

        debugLog("[WatchDownload] \(bookId): \(totalBytesWritten)/\(totalBytesExpectedToWrite) = \(String(format: "%.1f", progress * 100))%")

        Task {
            await WatchDownloadManager.shared.handleDownloadProgress(
                bookId: bookId,
                progress: progress,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let bookId = downloadTask.taskDescription else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("\(bookId)_download.epub")

        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.copyItem(at: location, to: tempFile)

            Task {
                await WatchDownloadManager.shared.handleDownloadComplete(
                    bookId: bookId,
                    tempURL: tempFile,
                    success: true
                )
            }
        } catch {
            debugLog("[WatchDownloadDelegate] Failed to copy downloaded file: \(error)")
            Task {
                await WatchDownloadManager.shared.handleDownloadComplete(
                    bookId: bookId,
                    tempURL: location,
                    success: false
                )
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let bookId = task.taskDescription else { return }

        if let error {
            debugLog("[WatchDownloadDelegate] Download error for \(bookId): \(error)")
            Task {
                await WatchDownloadManager.shared.handleDownloadComplete(
                    bookId: bookId,
                    tempURL: URL(fileURLWithPath: ""),
                    success: false
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        debugLog("[WatchDownloadDelegate] Background session finished events")
    }
}
#endif
