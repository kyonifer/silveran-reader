import SwiftUI

extension Notification.Name {
    static let appWillResignActive = Notification.Name("appWillResignActive")
}

struct SilveranReaderApp: App {
    @State private var mediaViewModel = MediaViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Task {
            do {
                if let credentials = try await AuthenticationActor.shared.loadCredentials() {
                    let _ = await StorytellerActor.shared.setLogin(
                        baseURL: credentials.url,
                        username: credentials.username,
                        password: credentials.password
                    )
                }
            } catch {
                debugLog(
                    "[SilveranReaderApp] Failed to load credentials: \(error.localizedDescription)"
                )
            }

            do {
                try await FilesystemActor.shared.copyWebResourcesFromBundle()
            } catch {
                debugLog(
                    "[SilveranReaderApp] Failed to copy web resources: \(error.localizedDescription)"
                )
            }

            await FilesystemActor.shared.cleanupExtractedEpubDirectories()

            await AppleWatchActor.shared.activate()
        }
    }

    var body: some Scene {
        WindowGroup("Library", id: "MyLibrary") {
            iOSLibraryView()
                .environment(mediaViewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .background:
                debugLog(
                    "[SilveranReaderApp] App entering background - posting resign notification"
                )
                NotificationCenter.default.post(name: .appWillResignActive, object: nil)

            case .active:
                debugLog("[SilveranReaderApp] App becoming active - refreshing metadata")
                Task {
                    let status = await StorytellerActor.shared.connectionStatus
                    if status == .connected {
                        debugLog("[SilveranReaderApp] Fetching library information from server")
                        let _ = await StorytellerActor.shared.fetchLibraryInformation()
                    } else {
                        debugLog(
                            "[SilveranReaderApp] Skipping metadata refresh - not connected to server"
                        )
                    }
                }

            case .inactive:
                break

            @unknown default:
                break
        }
    }
}
