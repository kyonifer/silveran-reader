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
