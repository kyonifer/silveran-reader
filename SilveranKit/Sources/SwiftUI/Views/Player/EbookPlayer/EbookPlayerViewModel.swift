import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
class EbookPlayerViewModel {
    let bookData: PlayerBookData?
    var settingsVM: SettingsViewModel

    var bookStructure: [SectionInfo] = []
    var mediaOverlayManager: MediaOverlayManager? = nil
    var progressManager: EbookProgressManager? = nil
    var styleManager: ReaderStyleManager? = nil
    var smilPlayerManager: SMILPlayerManager? = nil
    var searchManager: EbookSearchManager? = nil
    var extractedEbookPath: URL? = nil
    #if os(iOS)
    private(set) var recoveryManager: WebViewRecoveryManager?
    #endif

    var chapterList: [ChapterItem] {
        bookStructure.filter { $0.label != nil }.map {
            ChapterItem(id: $0.id, label: $0.label ?? "Untitled", href: $0.id, level: $0.level ?? 0)
        }
    }

    var hasAudioNarration: Bool = false
    var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    #if os(macOS)
    var showAudioSidebar = true
    var isTitleBarHovered = true
    #else
    var showAudioSidebar = false
    var showAudioSheet = false
    var isReadingBarVisible = true
    #endif
    var showCustomizePopover = false
    var commsBridge: WebViewCommsBridge? = nil
    var playbackProgressMessage: Any? = nil

    var chapterProgressBinding: Binding<Double> {
        Binding(
            get: { self.progressManager?.chapterSeekBarValue ?? 0.0 },
            set: { newValue in
                self.progressManager?.handleUserProgressSeek(newValue)
            }
        )
    }

    var uiSelectedChapterIdBinding: Binding<Int?> {
        Binding(
            get: { self.progressManager?.uiSelectedChapterId },
            set: { newValue in
                self.progressManager?.uiSelectedChapterId = newValue
            }
        )
    }

    var selectedChapterHref: String? {
        guard let index = progressManager?.selectedChapterId else { return nil }
        return bookStructure[safe: index]?.id
    }

    var sleepTimerActive = false
    var sleepTimerRemaining: TimeInterval? = nil
    var sleepTimerType: Any? = nil
    var lastRestartTime: Date? = nil
    var isSynced = true
    var showKeybindingsPopover = false
    var showSearchPanel = false

    init(bookData: PlayerBookData?, settingsVM: SettingsViewModel = SettingsViewModel()) {
        self.bookData = bookData
        self.settingsVM = settingsVM
    }


    func handleChapterSelectionByHref(_ href: String) {
        debugLog("[EbookPlayerViewModel] Chapter selected by href: \(href)")

        guard let chapterIndex = bookStructure.firstIndex(where: { $0.id == href }) else {
            debugLog("[EbookPlayerViewModel] Chapter not found for href: \(href)")
            return
        }

        debugLog("[EbookPlayerViewModel] Found chapter at index: \(chapterIndex)")
        progressManager?.handleUserChapterSelected(chapterIndex)
    }

    func handlePrevChapter() {
        guard let currentIndex = progressManager?.selectedChapterId else {
            debugLog("[EbookPlayerViewModel] Cannot navigate - no chapter selected")
            return
        }

        let currentChapter = bookStructure[safe: currentIndex]
        let currentProgress = progressManager?.chapterSeekBarValue ?? 0.0
        let now = Date()

        let justRestarted = if let lastRestart = lastRestartTime {
            now.timeIntervalSince(lastRestart) < 2.0
        } else {
            false
        }

        if currentProgress > 0.01 && !justRestarted {
            debugLog("[EbookPlayerViewModel] Restarting current chapter: \(currentChapter?.label ?? "nil") (was at \(Int(currentProgress * 100))%)")
            handleProgressSeek(0.0)
            lastRestartTime = now
        } else if currentIndex > 0 {
            let prevChapter = bookStructure[safe: currentIndex - 1]
            debugLog("[EbookPlayerViewModel] Navigating to previous chapter: \(prevChapter?.label ?? "nil")")
            progressManager?.handleUserChapterSelected(currentIndex - 1)
            lastRestartTime = nil
        } else {
            debugLog("[EbookPlayerViewModel] Already at beginning of first chapter")
            handleProgressSeek(0.0)
            lastRestartTime = now
        }
    }

    func handleNextChapter() {
        guard let currentIndex = progressManager?.selectedChapterId,
              currentIndex < bookStructure.count - 1 else {
            debugLog("[EbookPlayerViewModel] Cannot go to next chapter - at last chapter or no selection")
            return
        }

        let nextChapter = bookStructure[safe: currentIndex + 1]
        debugLog("[EbookPlayerViewModel] Navigating to next chapter: \(nextChapter?.label ?? "nil")")
        progressManager?.handleUserChapterSelected(currentIndex + 1)
    }

    func handlePlaybackRateChange(_ rate: Double) {
        debugLog("[EbookPlayerViewModel] Received playback rate change to \(rate)")
        settingsVM.defaultPlaybackSpeed = rate
        mediaOverlayManager?.setPlaybackRate(rate)

        Task { @MainActor in
            do {
                try await settingsVM.save()
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to save playback rate: \(error)")
            }
        }
    }

    func handleVolumeChange(_ newVolume: Double) {
        debugLog("[EbookPlayerViewModel] Received volume change to \(newVolume)")
        settingsVM.defaultVolume = newVolume
        mediaOverlayManager?.setVolume(newVolume)

        Task { @MainActor in
            do {
                try await settingsVM.save()
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to save volume: \(error)")
            }
        }
    }

    func handleSleepTimerStart(_ duration: TimeInterval?, _ type: SleepTimerType) {
        debugLog("[EbookPlayerViewModel] Starting sleep timer - type: \(type), duration: \(duration?.description ?? "N/A")")
        mediaOverlayManager?.startSleepTimer(duration: duration, type: type)
    }

    func handleSleepTimerCancel() {
        debugLog("[EbookPlayerViewModel] Cancelling sleep timer")
        mediaOverlayManager?.cancelSleepTimer()
    }

    func handleToggleOverlay() {
        #if os(iOS)
        isReadingBarVisible.toggle()
        debugLog("[EbookPlayerViewModel] Toggled overlay visibility: \(isReadingBarVisible)")
        #endif
    }

    func handleNextSentence() {
        mediaOverlayManager?.nextSentence()
    }

    func handlePrevSentence() {
        mediaOverlayManager?.prevSentence()
    }

    func handleProgressSeek(_ fraction: Double) {
        progressManager?.handleUserProgressSeek(fraction)
    }

    func handleColorSchemeChange(_ colorScheme: ColorScheme) {
        styleManager?.handleColorSchemeChange(colorScheme)
    }

    func handleAppBackgrounding() async {
        debugLog("[EbookPlayerViewModel] App backgrounding - syncing progress (audio continues in background)")

        await progressManager?.syncProgressToServer(force: true)

        debugLog("[EbookPlayerViewModel] Background sync complete")
    }

    func handleOnAppear() {
        #if os(iOS)
        recoveryManager = WebViewRecoveryManager(viewModel: self)
        #endif

        if let data = bookData {
            debugLog("[EbookPlayerViewModel] Book: \(data.metadata.title)")
            if data.category == .ebook {
                debugLog("[EbookPlayerViewModel] No audio playback mode")
            } else {
                debugLog("[EbookPlayerViewModel] Synced audio playback mode")
                hasAudioNarration = true
                #if os(macOS)
                showAudioSidebar = true
                #endif
            }
            if let localPath = data.localMediaPath {
                debugLog("[EbookPlayerViewModel] Local ebook file available")
                let needsNativeAudio = data.category == .synced
                Task { @MainActor in
                    do {
                        let processedPath = try await FilesystemActor.shared.extractEpubIfNeeded(
                            epubPath: localPath,
                            forceExtract: needsNativeAudio
                        )
                        self.extractedEbookPath = processedPath
                        debugLog("[EbookPlayerViewModel] EPUB processed for loading: \(processedPath.path)")
                    } catch {
                        debugLog("[EbookPlayerViewModel] Failed to extract EPUB: \(error)")
                        self.extractedEbookPath = localPath
                    }
                }
            } else {
                debugLog("[EbookPlayerViewModel] No local ebook file found")
            }
        }
    }

    func handleOnDisappear() {
        debugLog("[EbookPlayerViewModel] View disappearing")
        debugLog("[EbookPlayerViewModel] Window closing")

        Task { @MainActor in
            await mediaOverlayManager?.cleanup()
            smilPlayerManager?.cleanup()
            await progressManager?.cleanup()
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            smilPlayerManager?.reconcilePositionFromPlayer()
            if let syncData = smilPlayerManager?.getBackgroundSyncData() {
                debugLog("[EbookPlayerViewModel] Resuming from background - syncing view to audio position")
                Task { @MainActor in
                    await progressManager?.handleBackgroundSyncHandoff(syncData)
                }
            }
        case .background:
            debugLog("[EbookPlayerViewModel] Entering background - audio continues natively")
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func installBridgeHandlers(_ bridge: WebViewCommsBridge, initialColorScheme: ColorScheme) {
        debugLog("[EbookPlayerViewModel] Installing bridge handlers")

        #if os(iOS)
        recoveryManager?.setBridge(bridge)

        if recoveryManager?.isInRecovery == true {
            debugLog("[EbookPlayerViewModel] Recovery mode - updating existing managers with new bridge")
            progressManager?.commsBridge = bridge
            mediaOverlayManager?.commsBridge = bridge
            styleManager?.updateBridge(bridge)
            searchManager = EbookSearchManager(bridge: bridge)
            setupBridgeCallbacks(bridge, initialColorScheme: initialColorScheme)
            return
        }
        #endif

        searchManager = EbookSearchManager(bridge: bridge)
        debugLog("[EbookPlayerViewModel] SearchManager initialized")

        progressManager = EbookProgressManager(
            bridge: bridge,
            bookId: bookData?.metadata.uuid,
            initialLocator: bookData?.metadata.position?.locator
        )

        if let metadata = bookData?.metadata {
            progressManager?.bookTitle = metadata.title
            progressManager?.bookAuthor = metadata.authors?.first?.name

            Task {
                if let coverData = await FilesystemActor.shared.loadCoverImage(
                    uuid: metadata.uuid,
                    variant: "standard"
                ) {
                    await MainActor.run {
                        let base64 = coverData.base64EncodedString()
                        self.progressManager?.bookCoverUrl = "data:image/jpeg;base64,\(base64)"
                    }
                }
            }
        }

        styleManager = ReaderStyleManager(
            settingsVM: settingsVM,
            bridge: bridge
        )

        setupBridgeCallbacks(bridge, initialColorScheme: initialColorScheme)
    }

    private func setupBridgeCallbacks(_ bridge: WebViewCommsBridge, initialColorScheme: ColorScheme) {

        bridge.onBookStructureReady = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                debugLog("[EbookPlayerViewModel] BookStructureReady - \(message.sections.count) sections")
                self.bookStructure = message.sections

                #if os(iOS)
                let isRecovering = self.recoveryManager?.isInRecovery == true
                #else
                let isRecovering = false
                #endif

                self.progressManager?.bookStructure = message.sections

                if isRecovering {
                    #if os(iOS)
                    debugLog("[EbookPlayerViewModel] Recovery mode - reusing existing MOM/SMILPlayerManager")
                    self.mediaOverlayManager?.commsBridge = bridge
                    _ = self.recoveryManager?.handleBookStructureReadyIfRecovering()
                    #endif
                } else {
                    let manager = MediaOverlayManager(bookStructure: message.sections, bridge: bridge)
                    if manager.hasMediaOverlay {
                        debugLog("[EbookPlayerViewModel] Book has media overlay - MediaOverlayManager created")
                        manager.setPlaybackRate(self.settingsVM.defaultPlaybackSpeed)
                        self.mediaOverlayManager = manager
                        self.hasAudioNarration = true
                        self.progressManager?.mediaOverlayManager = manager
                        manager.progressManager = self.progressManager

                        let smilPlayer = SMILPlayerManager(
                            bookStructure: message.sections,
                            epubPath: self.bookData?.localMediaPath,
                            initialPlaybackRate: self.settingsVM.defaultPlaybackSpeed
                        )
                        smilPlayer.bookTitle = self.bookData?.metadata.title
                        smilPlayer.bookAuthor = self.bookData?.metadata.authors?.first?.name
                        smilPlayer.setVolume(self.settingsVM.defaultVolume)
                        self.smilPlayerManager = smilPlayer
                        debugLog("[EbookPlayerViewModel] SMILPlayerManager created for native audio")

                        manager.smilPlayerManager = smilPlayer
                        smilPlayer.delegate = manager
                        debugLog("[EbookPlayerViewModel] MOM connected to SMILPlayerManager (direct control)")

                        if let uuid = self.bookData?.metadata.uuid {
                            Task {
                                if let coverData = await FilesystemActor.shared.loadCoverImage(uuid: uuid, variant: "standard") {
                                    await MainActor.run {
                                        #if os(iOS)
                                        self.smilPlayerManager?.coverImage = UIImage(data: coverData)
                                        #elseif os(macOS)
                                        self.smilPlayerManager?.coverImage = NSImage(data: coverData)
                                        #endif
                                        debugLog("[EbookPlayerViewModel] Cover image set on SMILPlayerManager")
                                    }
                                }
                            }
                        }
                    } else {
                        debugLog("[EbookPlayerViewModel] Book has no media overlay")
                        self.mediaOverlayManager = nil
                        self.hasAudioNarration = false
                        self.progressManager?.mediaOverlayManager = nil
                        self.smilPlayerManager = nil
                    }

                    self.progressManager?.handleBookStructureReady()

                    Task { @MainActor in
                        let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
                        self.progressManager?.startPeriodicSync(syncInterval: syncInterval)
                    }
                }

                self.styleManager?.sendInitialStyles(colorScheme: initialColorScheme)
            }
        }

        bridge.onOverlayToggled = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleToggleOverlay()
            }
        }

        bridge.onPageFlipped = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.progressManager?.handleUserNavSwipeDetected()
            }
        }

        bridge.onMediaOverlaySeek = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.mediaOverlayManager?.handleSeekEvent(
                    sectionIndex: message.sectionIndex,
                    anchor: message.anchor
                )
            }
        }

        bridge.onMediaOverlayProgress = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.mediaOverlayManager?.handleProgressUpdate(message)
            }
        }

        bridge.onElementVisibility = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.mediaOverlayManager?.handleElementVisibility(message)
            }
        }
    }

    func handlePlaybackProgressUpdate(_ message: PlaybackProgressUpdateMessage) {
        playbackProgressMessage = message
        progressManager?.handlePlaybackProgressUpdate(message)
    }

    /// Navigate to search result - view only, no audio sync
    func handleSearchResultNavigation(_ result: SearchResult) {
        Task { @MainActor in
            await searchManager?.navigateToResult(result)
        }
    }
}
