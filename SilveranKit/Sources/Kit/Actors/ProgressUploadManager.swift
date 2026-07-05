import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProgressUploadRequest: Sendable {
    public let request: URLRequest
    public let body: Data

    public init(request: URLRequest, body: Data) {
        self.request = request
        self.body = body
    }
}

private struct ProgressUploadDescriptor {
    let bookId: String
    let timestampMillis: Int64
    let sourceID: BookSourceID

    var taskDescription: String { "\(bookId)|\(timestampMillis)|\(sourceID)" }
    var spoolToken: String { String(timestampMillis) }

    init(bookId: String, timestamp: Double, sourceID: BookSourceID) {
        self.bookId = bookId
        self.timestampMillis = Int64(timestamp)
        self.sourceID = sourceID
    }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(separator: "|", maxSplits: 2)
        guard parts.count == 3, let millis = Int64(parts[1]) else { return nil }
        bookId = String(parts[0])
        timestampMillis = millis
        sourceID = String(parts[2])
    }
}

/// Uploads pending progress positions through a background URLSession so the
/// system completes the POSTs when connectivity is available, even while the
/// app is suspended or terminated. Pairs with ProgressSyncActor's offline
/// queue: the queue stays authoritative, uploads here just confirm entries.
public actor ProgressUploadManager {
    public static let shared = ProgressUploadManager()

    #if os(watchOS)
    public static let sessionIdentifier = "com.kyonifer.silveran.watch.progressupload"
    #else
    public static let sessionIdentifier = "com.kyonifer.silveran.progressupload"
    #endif

    private let delegate = ProgressUploadDelegate()
    private lazy var uploadSession: URLSession = {
        #if os(Linux)
        let config = URLSessionConfiguration.default
        #else
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        #endif
        #if !os(Linux)
        config.waitsForConnectivity = true
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        #endif
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 12 * 3600

        return URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil,
        )
    }()

    private var backgroundCompletionHandler: (@Sendable () -> Void)?
    private var backstopScheduler: (@Sendable () async -> Void)?

    private init() {}

    /// Registered by the iOS app to schedule a BGAppRefresh backstop. A background
    /// upload that completes with a transient failure has no other wakeup: the app
    /// may have been launched solely by a watch relay and never sees an app-lifecycle
    /// transition, so without this the queue strands until the next relay or launch.
    public func setBackstopScheduler(_ scheduler: @escaping @Sendable () async -> Void) {
        backstopScheduler = scheduler
    }

    public func enqueuePendingUploads() async {
        await ProgressSyncActor.shared.resolveMissingSourceIDs()
        let pending = await ProgressSyncActor.shared.getPendingProgressSyncs()
            .filter { !$0.syncedToStoryteller && $0.sourceID != nil }
        guard !pending.isEmpty else { return }

        let outstanding = await outstandingTasks()

        for item in pending {
            guard let sourceID = item.sourceID else { continue }
            let descriptor = ProgressUploadDescriptor(
                bookId: item.bookId,
                timestamp: item.timestamp,
                sourceID: sourceID,
            )

            // Keep at most one in-flight upload per book, newest position wins,
            // so a stale in-flight body can never land after a newer one
            var alreadyInFlight = false
            for task in outstanding {
                guard
                    let existing = ProgressUploadDescriptor(
                        taskDescription: task.taskDescription
                    ),
                    existing.bookId == descriptor.bookId
                else { continue }
                if existing.timestampMillis >= descriptor.timestampMillis {
                    alreadyInFlight = true
                } else {
                    task.cancel()
                }
            }
            if alreadyInFlight { continue }

            guard
                let upload = await BookServiceActor.shared.createAuthenticatedPositionUploadRequest(
                    bookId: item.bookId,
                    sourceID: sourceID,
                    locator: item.locator,
                    timestamp: item.timestamp,
                )
            else {
                debugLog(
                    "[ProgressUploadManager] No upload request for \(item.bookId) (non-storyteller source or auth unavailable)"
                )
                continue
            }

            do {
                let fileURL = try await FilesystemActor.shared.writeProgressUploadSpoolFile(
                    bookId: item.bookId,
                    token: descriptor.spoolToken,
                    data: upload.body,
                )
                let task = uploadSession.uploadTask(with: upload.request, fromFile: fileURL)
                task.taskDescription = descriptor.taskDescription
                task.resume()
                debugLog(
                    "[ProgressUploadManager] Enqueued upload for \(item.bookId) ts=\(descriptor.timestampMillis)"
                )
            } catch {
                debugLog(
                    "[ProgressUploadManager] Failed to spool upload for \(item.bookId): \(error)"
                )
            }
        }

        // Reaching here means unsent work existed. Arm the backstop so the queue
        // still drains if no upload task was created (e.g. auth unavailable) or a
        // created task later fails with no app-lifecycle wakeup to retry.
        await scheduleBackstop()
    }

    func handleTaskCompletion(
        taskDescription: String?,
        statusCode: Int?,
        error: Error?,
    ) async {
        guard let descriptor = ProgressUploadDescriptor(taskDescription: taskDescription) else {
            return
        }

        await FilesystemActor.shared.removeProgressUploadSpoolFile(
            bookId: descriptor.bookId,
            token: descriptor.spoolToken,
        )

        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                debugLog(
                    "[ProgressUploadManager] Upload superseded for \(descriptor.bookId)"
                )
            } else {
                debugLog(
                    "[ProgressUploadManager] Upload failed for \(descriptor.bookId), leaving queued: \(error)"
                )
                await scheduleBackstop()
            }
            return
        }

        switch statusCode {
            case 204:
                await ProgressSyncActor.shared.confirmBackgroundUpload(
                    bookId: descriptor.bookId,
                    timestamp: Double(descriptor.timestampMillis),
                )
                debugLog("[ProgressUploadManager] Upload confirmed for \(descriptor.bookId)")
            case 401:
                debugLog(
                    "[ProgressUploadManager] Upload unauthorized for \(descriptor.bookId); next enqueue re-authenticates"
                )
                await scheduleBackstop()
            case 404, 409:
                // Same permanent-failure semantics as sendProgressToServer: the queue
                // entry stays and foreground reconciliation against server positions
                // resolves it. No backstop: a retry cannot change a permanent rejection.
                debugLog(
                    "[ProgressUploadManager] Upload rejected (\(statusCode ?? 0)) for \(descriptor.bookId)"
                )
            default:
                debugLog(
                    "[ProgressUploadManager] Upload for \(descriptor.bookId) completed with status \(statusCode.map(String.init) ?? "unknown")"
                )
                await scheduleBackstop()
        }
    }

    private func scheduleBackstop() async {
        await backstopScheduler?()
    }

    public func handleBackgroundSessionEvents(completionHandler: @escaping @Sendable () -> Void)
        async
    {
        _ = uploadSession
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

    private func outstandingTasks() async -> [URLSessionTask] {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<[URLSessionTask], Never>) in
            uploadSession.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
                continuation.resume(
                    returning: dataTasks as [URLSessionTask] + uploadTasks + downloadTasks
                )
            }
        }
    }
}

final class ProgressUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?,
    ) {
        let description = task.taskDescription
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        Task {
            await ProgressUploadManager.shared.handleTaskCompletion(
                taskDescription: description,
                statusCode: statusCode,
                error: error,
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        debugLog("[ProgressUploadManager] Background session finished events")
        Task {
            await ProgressUploadManager.shared.handleBackgroundSessionFinished()
        }
    }
}
