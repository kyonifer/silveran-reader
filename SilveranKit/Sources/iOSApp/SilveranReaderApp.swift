#if os(iOS)
import SilveranKitCommon
import SilveranKitSwiftUI
import SwiftUI
import UIKit

extension Notification.Name {
    static let appWillResignActive = Notification.Name("appWillResignActive")
}

class SilveranAppDelegate: NSObject, UIApplicationDelegate {
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

    init() {
        StorytellerFontRegistration.registerBundledFonts()
        let vm = MediaViewModel()
        _mediaViewModel = State(initialValue: vm)

        startupTask = Task {
            await SilveranMigrations.runMigrations()
            await BookServiceActor.shared.reloadSourceRegistry()

            do {
                try await FilesystemActor.shared.copyWebResourcesFromBundle()
            } catch {
                debugLog(
                    "[SilveranReaderApp] Failed to copy web resources: \(error.localizedDescription)"
                )
            }

            if LastOpenBookStore.hasSavedRoute {
                debugLog(
                    "[SilveranReaderApp] Skipping extracted EPUB cleanup because a last-open book route is pending"
                )
            } else {
                await FilesystemActor.shared.cleanupExtractedEpubDirectories()
            }

            await AppleWatchActor.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup("Library", id: "MyLibrary") {
            iOSRootView(startupTask: startupTask)
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
    }

    private func handleDidEnterBackground() {
        debugLog(
            "[SilveranReaderApp] App entering background - posting resign notification"
        )
        NotificationCenter.default.post(name: .appWillResignActive, object: nil)
        Task {
            await BookServiceActor.shared.setActive(false, source: .app)
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
    let startupTask: Task<Void, Never>
    @State private var restoreStartupFinished = !LastOpenBookStore.hasSavedRoute
    @State private var restoredPlayer: PlayerBookData?

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
        .task {
            guard !restoreStartupFinished else { return }
            await startupTask.value
            restoredPlayer = await LastOpenBookStore.loadPlayerBookData()
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
