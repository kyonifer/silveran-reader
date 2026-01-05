import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct SilveranTVApp: App {
    @State private var mediaViewModel = MediaViewModel()

    var body: some Scene {
        WindowGroup {
            TVContentView()
                .environment(mediaViewModel)
                .task {
                    await initializeStorytellerConnection()
                }
        }
    }

    private func initializeStorytellerConnection() async {
        do {
            if let credentials = try await AuthenticationActor.shared.loadCredentials() {
                let success = await StorytellerActor.shared.setLogin(
                    baseURL: credentials.url,
                    username: credentials.username,
                    password: credentials.password
                )
                if success {
                    debugLog("[TVApp] Storyteller connected successfully")
                    await syncOnLaunch()
                    await mediaViewModel.refreshMetadata(source: "tvApp.login")
                } else {
                    debugLog("[TVApp] Storyteller connection failed")
                }
            } else {
                debugLog("[TVApp] No Storyteller credentials configured")
            }
        } catch {
            debugLog("[TVApp] Failed to load Storyteller credentials: \(error)")
        }
    }

    private func syncOnLaunch() async {
        let result = await ProgressSyncActor.shared.syncPendingQueue()
        debugLog("[TVApp] Sync on launch: synced=\(result.synced), failed=\(result.failed)")

        if let library = await StorytellerActor.shared.fetchLibraryInformation() {
            try? await LocalMediaActor.shared.updateStorytellerMetadata(library)
            debugLog("[TVApp] Library metadata updated: \(library.count) books")
        }
    }
}
