#if os(iOS)
import SilveranKitCommon
import SilveranKitReadaloudGenerator
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
    private let restorePrerequisitesTask: Task<Void, Never>

    init() {
        StorytellerFontRegistration.registerBundledFonts()
        let vm = MediaViewModel()
        _mediaViewModel = State(initialValue: vm)

        // The fast, local-only work a restored book actually depends on: migrations and the web
        // resources the reader webview loads. Restoring blocks on this, not on the full startup, so
        // the slow network library refresh never sits on the restore critical path.
        let prerequisites = Task {
            let started = CFAbsoluteTimeGetCurrent()
            await SilveranMigrations.runMigrations()
            do {
                try await FilesystemActor.shared.copyWebResourcesFromBundle()
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

            await AppleWatchActor.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup("Library", id: "MyLibrary") {
            iOSRootView(restorePrerequisitesTask: restorePrerequisitesTask)
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
