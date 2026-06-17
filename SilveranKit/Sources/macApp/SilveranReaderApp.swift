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

@MainActor
private enum WindowMenuShortcutInstaller {
    private static var didInstall = false
    private static var observer: NSObjectProtocol?

    static func install() {
        guard !didInstall else { return }
        didInstall = true

        Task { @MainActor in
            apply()
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main,
        ) { _ in
            Task { @MainActor in
                apply()
            }
        }
    }

    private static func apply() {
        guard let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu else { return }

        setShortcut(
            in: windowMenu,
            title: "Library",
            key: "l",
            modifiers: [.command],
        )
        setShortcut(
            in: windowMenu,
            title: "Debug Log",
            key: "d",
            modifiers: [.command, .option],
        )
        setShortcut(
            in: windowMenu,
            title: "Content Server",
            key: "c",
            modifiers: [.command, .shift],
        )
        setShortcut(
            in: windowMenu,
            title: "MP3 to M4B Converter",
            key: "m",
            modifiers: [.command, .shift],
        )
    }

    private static func setShortcut(
        in menu: NSMenu,
        title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
    ) {
        guard let item = menu.items.first(where: { $0.title == title }) else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
    }
}

// TODO: Remove most of this when proper book opening is implemented.
// This is debug code
struct SilveranReaderApp: App {
    @State private var mediaViewModel = MediaViewModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var didOpenSecondaryWindows = false

    init() {
        StorytellerFontRegistration.registerBundledFonts()
        SidebarSelectionColor.install()
        WindowMenuShortcutInstaller.install()
        Task {
            await SilveranMigrations.runMigrations()
            await BookServiceActor.shared.reloadSourceRegistry()

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
        readaloudGeneratorScene
        contentServerScene
        mp3ToM4BConverterScene
        serverMediaManagementScene
        uploadNewBookScene
        bulkImportFolderScene
        metadataEditorScene
        #endif
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .background:
                debugLog("[macApp] App entering background")
                Task {
                    await BookServiceActor.shared.setActive(false, source: .mac)
                }
            case .active:
                debugLog("[macApp] App becoming active")
                Task {
                    await BookServiceActor.shared.setActive(true, source: .mac)
                }
            case .inactive:
                break
            @unknown default:
                break
        }
    }

    private var debugLogScene: some Scene {
        Window("Debug Log", id: "DebugLog") {
            DebugLogView()
        }
        .defaultSize(width: 800, height: 500)
    }

    private var libraryScene: some Scene {
        Window("Library", id: "MyLibrary") {
            libraryViewContent
        }
        .windowStyle(.hiddenTitleBar)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .commands {
            // Most secondary windows (reader, metadata editor, server tools) only make
            // sense when opened from a book context, so drop the synthesized File > New items.
            CommandGroup(replacing: .newItem) {}
        }
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
                await BookServiceActor.shared.setActive(true, source: .mac)
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

    private var readaloudGeneratorScene: some Scene {
        WindowGroup("Create Readaloud", id: "ReadaloudGenerator", for: ReadaloudGeneratorData.self)
        {
            data in
            ReadaloudGeneratorView(initialData: data.wrappedValue)
                .environment(mediaViewModel)
        }
        .windowResizability(.contentSize)
        .disableWindowRestoration()
        .commands {
            CommandMenu("Utilities") {
                Button("Create Readaloud...") {
                    openWindow(id: "ReadaloudGenerator")
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }
        }
    }

    private var contentServerScene: some Scene {
        Window("Content Server", id: "ContentServer") {
            ContentServerView()
        }
        .windowResizability(.contentSize)
        .disableWindowRestoration()
    }

    private var mp3ToM4BConverterScene: some Scene {
        Window("MP3 to M4B Converter", id: "MP3ToM4BConverter") {
            MP3ToM4BConverterView()
        }
        .windowResizability(.contentSize)
        .disableWindowRestoration()
    }

    private var serverMediaManagementScene: some Scene {
        WindowGroup(
            "Server Media Management",
            id: "ServerMediaManagement",
            for: ServerMediaManagementData.self,
        ) { data in
            if let bookId = data.wrappedValue?.bookId {
                ServerMediaManagementView(bookId: bookId)
                    .environment(mediaViewModel)
            }
        }
        .windowResizability(.contentSize)
        .disableWindowRestoration()
    }

    private var uploadNewBookScene: some Scene {
        WindowGroup("Upload New Book", id: "UploadNewBook", for: UploadNewBookData.self) { data in
            UploadNewBookView(initialSourceID: data.wrappedValue?.sourceID)
                .environment(mediaViewModel)
        }
        .windowResizability(.contentSize)
        .disableWindowRestoration()
    }

    private var bulkImportFolderScene: some Scene {
        WindowGroup("Bulk Import", id: "BulkImportFolder", for: BulkImportFolderData.self) { data in
            BulkImportFolderView(initialSourceID: data.wrappedValue?.sourceID)
                .environment(mediaViewModel)
        }
        .defaultSize(width: 1080, height: 720)
        .defaultPosition(.top)
        .disableWindowRestoration()
    }

    private var metadataEditorScene: some Scene {
        WindowGroup("Edit Metadata", id: "MetadataEditor", for: MetadataEditorData.self) { data in
            MetadataEditorSceneContent(data: data.wrappedValue)
                .environment(mediaViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 710)
        .disableWindowRestoration()
    }
}

private struct MetadataEditorSceneContent: View {
    @Environment(\.dismiss) private var dismiss
    let data: MetadataEditorData?

    var body: some View {
        if let data {
            MetadataEditorView(initialBookIds: data.bookIds)
        } else {
            Color.clear
                .onAppear {
                    dismiss()
                }
        }
    }
}
