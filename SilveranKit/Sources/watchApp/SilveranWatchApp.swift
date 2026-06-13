#if os(watchOS)
import SilveranKitCommon
import SwiftUI
import WatchConnectivity
import WatchKit

class SilveranWatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask {
                if urlTask.sessionIdentifier == "com.kyonifer.silveran.watch.downloads" {
                    Task {
                        await DownloadManager.shared.handleBackgroundSessionEvents {
                            urlTask.setTaskCompletedWithSnapshot(false)
                        }
                    }
                } else {
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

struct SilveranWatchApp: App {
    @WKApplicationDelegateAdaptor(SilveranWatchAppDelegate.self) var appDelegate
    @State private var watchViewModel = WatchViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchViewModel)
                .task {
                    await BookServiceActor.shared.setActive(true, source: .watch)
                    await initializeBookSources()
                    // Start DownloadManager init + retry loop. On iOS/macOS/tvOS this
                    // happens via MediaViewModel.setupDownloadManagerObserver() instead.
                    _ = await DownloadManager.shared.incompleteDownloads
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .background:
                debugLog("[WatchApp] App entering background")
                Task {
                    await BookServiceActor.shared.setActive(false, source: .watch)
                }

            case .active:
                debugLog("[WatchApp] App becoming active")
                Task {
                    await BookServiceActor.shared.setActive(true, source: .watch)
                }

            case .inactive:
                break

            @unknown default:
                break
        }
    }

    private func initializeBookSources() async {
        await SilveranMigrations.runMigrations()
        await BookServiceActor.shared.reloadSourceRegistry()
        await syncOnLaunch()
    }

    private func syncOnLaunch() async {
        let result = await ProgressSyncActor.shared.syncPendingQueue()
        debugLog("[WatchApp] Sync on launch: synced=\(result.synced), failed=\(result.failed)")

        if let library = await BookServiceActor.shared.fetchLibraryInformation() {
            try? await BookServiceActor.shared.updateLibraryCacheMetadata(library)
            debugLog("[WatchApp] Library metadata updated: \(library.count) books")
        }
    }
}

struct ContentView: View {
    @Environment(WatchViewModel.self) private var viewModel

    var body: some View {
        ZStack {
            if viewModel.receivingTitle != nil {
                TransferProgressView()
            } else {
                WatchModeSelectionView()
            }
        }
    }
}
#endif
