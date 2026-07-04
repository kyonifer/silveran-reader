#if os(iOS)
import BackgroundTasks
import SilveranKit
import SwiftUI
import UIKit

class SilveranAppDelegate: NSObject, UIApplicationDelegate {
    static let progressSyncTaskIdentifier = "com.kyonifer.silveran.progresssync.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.progressSyncTaskIdentifier,
            using: nil,
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleProgressSyncRefresh(refreshTask)
        }
        return true
    }

    private static func handleProgressSyncRefresh(_ task: BGAppRefreshTask) {
        debugLog("[SilveranAppDelegate] Progress sync background refresh fired")
        let work = Task {
            _ = await ProgressSyncActor.shared.syncPendingQueue()
            await ProgressUploadManager.shared.enqueuePendingUploads()
            await Self.scheduleProgressSyncRefreshIfNeeded()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            debugLog("[SilveranAppDelegate] Progress sync background refresh expired")
            work.cancel()
        }
    }

    static func scheduleProgressSyncRefreshIfNeeded() async {
        let hasPending = await ProgressSyncActor.shared.getPendingProgressSyncs()
            .contains { !$0.syncedToStoryteller }
        guard hasPending else { return }

        let request = BGAppRefreshTaskRequest(identifier: progressSyncTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            debugLog("[SilveranAppDelegate] Scheduled progress sync background refresh")
        } catch {
            debugLog(
                "[SilveranAppDelegate] Failed to schedule progress sync refresh: \(error)"
            )
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void,
    ) {
        if identifier == "com.kyonifer.silveran.downloads" {
            nonisolated(unsafe) let handler = completionHandler
            Task {
                await DownloadManager.shared.handleBackgroundSessionEvents {
                    handler()
                }
            }
        } else if identifier == ProgressUploadManager.sessionIdentifier {
            nonisolated(unsafe) let handler = completionHandler
            Task {
                await ProgressUploadManager.shared.handleBackgroundSessionEvents {
                    handler()
                }
            }
        } else {
            completionHandler()
        }
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        let available = os_proc_available_memory()
        debugLog(
            "[SilveranAppDelegate] Memory warning received - available: \(available / 1_048_576) MB"
        )
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        debugLog("[SilveranAppDelegate] Protected data became available (device unlocked)")
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        debugLog("[SilveranAppDelegate] Protected data will become unavailable (device locking)")
    }
}

struct SilveranReaderApp: App {
    @UIApplicationDelegateAdaptor(SilveranAppDelegate.self) var appDelegate
    @State private var mediaViewModel: MediaViewModel
    private let startupTask: Task<Void, Never>
    private let restorePrerequisitesTask: Task<Void, Never>

    init() {
        StorytellerFontRegistration.registerBundledFonts()

        // Activate WCSession immediately rather than at the end of startup: a queued
        // watch transfer can background-launch the app with very little runtime, and
        // the system holds delivery until a delegate is set and activated.
        Task { await AppleWatchActor.shared.activate() }

        Task {
            await ProgressUploadManager.shared.setBackstopScheduler {
                await SilveranAppDelegate.scheduleProgressSyncRefreshIfNeeded()
            }
        }

        let vm = MediaViewModel()
        _mediaViewModel = State(initialValue: vm)

        // The fast, local-only work a restored book actually depends on: migrations and the web
        // resources the reader webview loads. Restoring blocks on this, not on the full startup, so
        // the slow network library refresh never sits on the restore critical path.
        let prerequisites = Task {
            let started = CFAbsoluteTimeGetCurrent()
            await SilveranMigrations.runMigrations()
            do {
                let webResourcesURL = try AppleKitResources.webResourcesDirectory()
                try await FilesystemActor.shared.copyWebResources(from: webResourcesURL)
            } catch {
                debugLog(
                    "[SilveranReaderApp] Failed to copy web resources: \(error.localizedDescription)"
                )
            }
            debugLog(
                "[RestoreTrace][Startup] prerequisites deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - started) * 1000))"
            )
        }
        restorePrerequisitesTask = prerequisites

        startupTask = Task {
            await prerequisites.value
            let started = CFAbsoluteTimeGetCurrent()
            await BookServiceActor.shared.refreshLibraryFromSources()
            debugLog(
                "[RestoreTrace][Startup] refreshLibraryFromSources deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - started) * 1000))"
            )

            if LastOpenBookStore.hasSavedRoute {
                debugLog(
                    "[SilveranReaderApp] Skipping extracted EPUB cleanup because a last-open book route is pending"
                )
            } else {
                await FilesystemActor.shared.cleanupExtractedEpubDirectories()
            }
        }
    }

    var body: some Scene {
        WindowGroup("Library", id: "MyLibrary") {
            iOSRootView(restorePrerequisitesTask: restorePrerequisitesTask)
                .environment(AppLaunchContext.environment)
                .environment(mediaViewModel)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    handleDidEnterBackground()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    handleDidBecomeActive()
                }
                .task {
                    if UIApplication.shared.applicationState == .active {
                        handleDidBecomeActive()
                    }
                }
        }
        .commands {
            CommandMenu("Go") {
                Button("Show Library") {
                    NotificationCenter.default.post(name: .silveranShowLibrary, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Open Reader") {
                    NotificationCenter.default.post(name: .silveranShowReader, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func handleDidEnterBackground() {
        debugLog(
            "[SilveranReaderApp] App entering background - posting resign notification"
        )
        NotificationCenter.default.post(name: .appWillResignActive, object: nil)
        Task {
            await BookServiceActor.shared.setActive(false, source: .app)
        }

        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            // Give players reacting to appWillResignActive a moment to queue their
            // final positions before spooling them into background upload tasks
            try? await Task.sleep(for: .seconds(2))
            await ProgressUploadManager.shared.enqueuePendingUploads()
            await SilveranAppDelegate.scheduleProgressSyncRefreshIfNeeded()

            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    private func handleDidBecomeActive() {
        debugLog("[SilveranReaderApp] App becoming active")
        Task {
            await BookServiceActor.shared.setActive(true, source: .app)
        }
    }
}

private struct iOSRootView: View {
    let restorePrerequisitesTask: Task<Void, Never>
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var restoreStartupFinished = !LastOpenBookStore.hasSavedRoute
    @State private var restoredPlayer: PlayerBookData?
    @State private var readaloudGeneratorData: ReadaloudGeneratorData?

    var body: some View {
        Group {
            if !restoreStartupFinished {
                ProgressView("Loading book...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let restoredPlayer {
                NavigationStack {
                    restoredPlayerView(for: restoredPlayer)
                }
            } else {
                iOSLibraryView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .silveranCreateReadaloud)) {
            notification in
            guard AppLaunchContext.environment.readaloudAligner != nil else { return }
            readaloudGeneratorData = notification.object as? ReadaloudGeneratorData
        }
        .sheet(item: $readaloudGeneratorData) { data in
            NavigationStack {
                ReadaloudGeneratorView(initialData: data)
                    .environment(mediaViewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                readaloudGeneratorData = nil
                            }
                        }
                    }
            }
        }
        .task {
            guard !restoreStartupFinished else { return }
            let restoreStarted = CFAbsoluteTimeGetCurrent()
            await restorePrerequisitesTask.value
            let afterStartup = CFAbsoluteTimeGetCurrent()
            debugLog(
                "[RestoreTrace][Restore] awaitPrerequisites deltaMs=\(String(format: "%.1f", (afterStartup - restoreStarted) * 1000))"
            )
            restoredPlayer = await LastOpenBookStore.loadPlayerBookData()
            debugLog(
                "[RestoreTrace][Restore] loadPlayerBookData deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - afterStartup) * 1000))"
            )
            restoreStartupFinished = true
        }
    }

    @ViewBuilder
    private func restoredPlayerView(for bookData: PlayerBookData) -> some View {
        switch bookData.category {
            case .audio:
                AudiobookPlayerView(
                    bookData: bookData,
                    onClose: {
                        restoredPlayer = nil
                    },
                )
            case .ebook, .synced:
                EbookPlayerView(
                    bookData: bookData,
                    onClose: {
                        restoredPlayer = nil
                    },
                )
        }
    }
}
#endif
