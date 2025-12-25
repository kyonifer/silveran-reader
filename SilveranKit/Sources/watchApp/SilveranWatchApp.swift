import SilveranKitCommon
import SwiftUI
import WatchConnectivity

struct SilveranWatchApp: App {
    @State private var watchViewModel = WatchViewModel()

    init() {
        WatchSessionManager.shared.activate()
        WatchStorageManager.shared.cleanupOrphanedFiles()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchViewModel)
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
                    debugLog("[WatchApp] Storyteller connected successfully")
                } else {
                    debugLog("[WatchApp] Storyteller connection failed")
                }
            } else {
                debugLog("[WatchApp] No Storyteller credentials configured")
            }
        } catch {
            debugLog("[WatchApp] Failed to load Storyteller credentials: \(error)")
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
