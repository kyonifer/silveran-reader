#if os(iOS)
import BackgroundTasks
import SilveranAppleWidgets
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
            using: DispatchQueue.main,
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
            guard await SilveranRuntime.start() else {
                task.setTaskCompleted(success: false)
                return
            }
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
        guard await SilveranRuntime.start() else { return }
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
                guard await SilveranRuntime.start() else {
                    handler()
                    return
                }
                await DownloadManager.shared.handleBackgroundSessionEvents {
                    handler()
                }
            }
        } else if identifier == ProgressUploadManager.sessionIdentifier {
            nonisolated(unsafe) let handler = completionHandler
            Task {
                guard await SilveranRuntime.start() else {
                    handler()
                    return
                }
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
    private let startupTask: Task<Bool, Never>
    private let restorePrerequisitesTask: Task<Bool, Never>

    init() {
        StorytellerFontRegistration.registerBundledFonts()

        let vm = MediaViewModel()
        _mediaViewModel = State(initialValue: vm)

        // The fast, local-only work a restored book actually depends on: migrations and the web
        // resources the reader webview loads. Restoring blocks on this, not on the full startup, so
        // the slow network library refresh never sits on the restore critical path.
        let prerequisites = Task {
            let started = CFAbsoluteTimeGetCurrent()
            guard await SilveranRuntime.start() else { return false }
            await vm.start()
            await AppleWatchActor.shared.activate()
            await ProgressUploadManager.shared.setBackstopScheduler {
                await SilveranAppDelegate.scheduleProgressSyncRefreshIfNeeded()
            }
            do {
                let webResourcesURL = try KitResources.webResourcesDirectory()
                try await FilesystemActor.shared.copyWebResources(from: webResourcesURL)
            } catch {
                debugLog(
                    "[SilveranReaderApp] Failed to copy web resources: \(error.localizedDescription)"
                )
            }
            debugLog(
                "[RestoreTrace][Startup] prerequisites deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - started) * 1000))"
            )
            return true
        }
        restorePrerequisitesTask = prerequisites

        startupTask = Task {
            guard await prerequisites.value else { return false }
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
            return true
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
            guard await SilveranRuntime.start() else { return }
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
            guard await SilveranRuntime.start() else {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
                return
            }
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
            guard await SilveranRuntime.start() else { return }
            await BookServiceActor.shared.setActive(true, source: .app)
        }
    }
}

private struct iOSRootView: View {
    let restorePrerequisitesTask: Task<Bool, Never>
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var restoreStartupFinished = false
    @State private var readaloudGeneratorData: ReadaloudGeneratorData?

    var body: some View {
        Group {
            if !restoreStartupFinished {
                ProgressView(LastOpenBookStore.hasSavedRoute ? "Loading book..." : "Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .task {
            let restoreStarted = CFAbsoluteTimeGetCurrent()
            guard await restorePrerequisitesTask.value else { return }
            let afterStartup = CFAbsoluteTimeGetCurrent()
            debugLog(
                "[RestoreTrace][Restore] awaitPrerequisites deltaMs=\(String(format: "%.1f", (afterStartup - restoreStarted) * 1000))"
            )
            if mediaViewModel.pendingOpenBookID == nil {
                if let bookData = await LastOpenBookStore.loadPlayerBookData(),
                    mediaViewModel.pendingOpenBookID == nil
                {
                    PlayerPresenter.shared.present(bookData)
                }
            }
            debugLog(
                "[RestoreTrace][Restore] loadPlayerBookData deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - afterStartup) * 1000))"
            )
            restoreStartupFinished = true
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard let bookID = SilveranBookLink.bookID(from: url) else { return }
        mediaViewModel.pendingOpenBookID = bookID
    }
}
#endif
