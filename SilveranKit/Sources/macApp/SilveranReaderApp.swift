import AppKit
import SwiftUI

extension Scene {
    func disableWindowRestoration() -> some Scene {
        if #available(macOS 15.0, *) {
            return self.restorationBehavior(.disabled)
        } else {
            return self
        }
    }
}

// TODO: Remove most of this when proper book opening is implemented.
// This is debug code
struct SilveranReaderApp: App {
    @State private var mediaViewModel = MediaViewModel()
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenSecondaryWindows = false

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

            debugLog("[SilveranReaderApp] Syncing pending progress queue on launch")
            let (synced, failed) = await ProgressSyncActor.shared.syncPendingQueue()
            debugLog("[SilveranReaderApp] Queue sync: synced=\(synced), failed=\(failed)")
        }
    }

    var body: some Scene {
        libraryScene
        #if os(macOS)
        audiobookScene
        ebookScene
        settingsScene
        debugLogScene
        #endif
    }

    private var debugLogScene: some Scene {
        Window("Debug Log", id: "DebugLog") {
            DebugLogView()
        }
        .defaultSize(width: 800, height: 500)
        .commands {
            CommandGroup(after: .help) {
                Button("Debug Log...") {
                    openWindow(id: "DebugLog")
                }
                .keyboardShortcut("D", modifiers: [.command, .option])
            }
        }
    }

    private var libraryScene: some Scene {
        Window("Library", id: "MyLibrary") {
            libraryViewContent
        }
        .windowStyle(.hiddenTitleBar)
    }

    private var libraryViewContent: some View {
        LibraryView()
            .environment(mediaViewModel)
            #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
            #else
        .background(Color(uiColor: .systemBackground))
            #endif
            .task {
                guard !didOpenSecondaryWindows else { return }
                didOpenSecondaryWindows = true
            }
    }

    private var audiobookScene: some Scene {
        WindowGroup("Audiobook Player", id: "AudiobookPlayer", for: PlayerBookData.self) {
            bookData in
            AudiobookPlayerView(bookData: bookData.wrappedValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 420, height: 720)
        .disableWindowRestoration()
    }

    private var ebookScene: some Scene {
        WindowGroup("Ebook Reader", id: "EbookPlayer", for: PlayerBookData.self) { bookData in
            EbookPlayerView(bookData: bookData.wrappedValue)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1228, height: 768)
        .disableWindowRestoration()
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView()
        }
    }
}
