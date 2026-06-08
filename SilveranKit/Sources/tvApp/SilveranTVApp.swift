import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct SilveranTVApp: App {
    @State private var mediaViewModel = MediaViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVContentView()
                .environment(mediaViewModel)
                .task {
                    await BookServiceActor.shared.setActive(true, source: .tv)
                    await initializeBookSources()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .background:
                debugLog("[TVApp] App entering background")
                Task {
                    await BookServiceActor.shared.setActive(false, source: .tv)
                }
            case .active:
                debugLog("[TVApp] App becoming active")
                Task {
                    await BookServiceActor.shared.setActive(true, source: .tv)
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
        await mediaViewModel.refreshMetadata(source: "tvApp.registry")
    }

    private func syncOnLaunch() async {
        let result = await ProgressSyncActor.shared.syncPendingQueue()
        debugLog("[TVApp] Sync on launch: synced=\(result.synced), failed=\(result.failed)")

        if let library = await BookServiceActor.shared.fetchLibraryInformation() {
            try? await BookServiceActor.shared.updateLibraryCacheMetadata(library)
            debugLog("[TVApp] Library metadata updated: \(library.count) books")
        }
    }
}
