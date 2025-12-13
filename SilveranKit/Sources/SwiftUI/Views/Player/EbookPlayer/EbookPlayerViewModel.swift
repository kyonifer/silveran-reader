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
    var searchManager: EbookSearchManager? = nil
    var extractedEbookPath: URL? = nil
    private var nativeLoadingTask: Task<Void, Never>? = nil
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
    var isTopBarVisible = true
    var collapseCardTrigger = 0
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
    var isJoiningExistingSession = false
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

        let justRestarted =
            if let lastRestart = lastRestartTime {
                now.timeIntervalSince(lastRestart) < 2.0
            } else {
                false
            }

        if currentProgress > 0.01 && !justRestarted {
            debugLog(
                "[EbookPlayerViewModel] Restarting current chapter: \(currentChapter?.label ?? "nil") (was at \(Int(currentProgress * 100))%)"
            )
            handleProgressSeek(0.0)
            lastRestartTime = now
        } else if currentIndex > 0 {
            let prevChapter = bookStructure[safe: currentIndex - 1]
            debugLog(
                "[EbookPlayerViewModel] Navigating to previous chapter: \(prevChapter?.label ?? "nil")"
            )
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
            currentIndex < bookStructure.count - 1
        else {
            debugLog(
                "[EbookPlayerViewModel] Cannot go to next chapter - at last chapter or no selection"
            )
            return
        }

        let nextChapter = bookStructure[safe: currentIndex + 1]
        debugLog(
            "[EbookPlayerViewModel] Navigating to next chapter: \(nextChapter?.label ?? "nil")"
        )
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
        debugLog(
            "[EbookPlayerViewModel] Starting sleep timer - type: \(type), duration: \(duration?.description ?? "N/A")"
        )
        mediaOverlayManager?.startSleepTimer(duration: duration, type: type)
    }

    func handleSleepTimerCancel() {
        debugLog("[EbookPlayerViewModel] Cancelling sleep timer")
        mediaOverlayManager?.cancelSleepTimer()
    }

    func handleToggleOverlay() {
        #if os(iOS)
        if settingsVM.alwaysShowMiniPlayer {
            isTopBarVisible.toggle()
            if !isTopBarVisible {
                collapseCardTrigger += 1
            }
            debugLog("[EbookPlayerViewModel] Toggled top bar visibility: \(isTopBarVisible)")
        } else {
            isReadingBarVisible.toggle()
            isTopBarVisible = isReadingBarVisible
            debugLog("[EbookPlayerViewModel] Toggled overlay visibility: \(isReadingBarVisible)")
        }
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
        debugLog(
            "[EbookPlayerViewModel] App backgrounding - syncing progress (audio continues in background)"
        )

        await progressManager?.syncProgressToServer(reason: .appBackgrounding)

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
                nativeLoadingTask = Task { @MainActor in
                    do {
                        let processedPath = try await FilesystemActor.shared.extractEpubIfNeeded(
                            epubPath: localPath,
                            forceExtract: needsNativeAudio
                        )
                        self.extractedEbookPath = processedPath
                        debugLog(
                            "[EbookPlayerViewModel] EPUB processed for loading: \(processedPath.path)"
                        )

                        if needsNativeAudio {
                            await loadBookIntoActor(epubPath: localPath)
                        }
                    } catch {
                        debugLog("[EbookPlayerViewModel] Failed to extract EPUB: \(error)")
                    }
                }
            } else {
                debugLog("[EbookPlayerViewModel] No local ebook file found")
            }
        }
    }

    private func loadBookIntoActor(epubPath: URL) async {
        let currentBookId = bookData?.metadata.uuid ?? "unknown"
        let loadedBookId = await SMILPlayerActor.shared.getLoadedBookId()

        if loadedBookId == currentBookId {
            debugLog("[EbookPlayerViewModel] Book already loaded in actor, joining existing session")
            isJoiningExistingSession = true
            let nativeStructure = await SMILPlayerActor.shared.getBookStructure()
            self.bookStructure = nativeStructure
            debugLog("[EbookPlayerViewModel] Joined session with \(nativeStructure.count) sections")
            return
        }

        do {
            try await SMILPlayerActor.shared.loadBook(
                epubPath: epubPath,
                bookId: currentBookId,
                title: bookData?.metadata.title,
                author: bookData?.metadata.authors?.first?.name
            )
            await SMILPlayerActor.shared.setPlaybackRate(settingsVM.defaultPlaybackSpeed)
            await SMILPlayerActor.shared.setVolume(settingsVM.defaultVolume)

            let nativeStructure = await SMILPlayerActor.shared.getBookStructure()
            self.bookStructure = nativeStructure
            debugLog(
                "[EbookPlayerViewModel] Native book structure loaded: \(nativeStructure.count) sections"
            )

            #if os(iOS)
            if let uuid = bookData?.metadata.uuid {
                if let coverData = await FilesystemActor.shared.loadCoverImage(
                    uuid: uuid,
                    variant: "standard"
                ) {
                    if let image = UIImage(data: coverData) {
                        await SMILPlayerActor.shared.setCoverImage(image)
                        debugLog("[EbookPlayerViewModel] Cover image set on SMILPlayerActor")
                    }
                }
            }
            #endif
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to load book into actor: \(error)")
        }
    }

    private func reloadBookIntoActor() async {
        guard let localPath = bookData?.localMediaPath else {
            debugLog("[EbookPlayerViewModel] reloadBookIntoActor - no local path")
            return
        }

        debugLog("[EbookPlayerViewModel] Reloading book into actor")

        let savedSectionIndex = mediaOverlayManager?.cachedSectionIndex ?? 0
        let savedEntryIndex = mediaOverlayManager?.cachedEntryIndex ?? 0

        await loadBookIntoActor(epubPath: localPath)

        if savedSectionIndex > 0 || savedEntryIndex > 0 {
            do {
                try await SMILPlayerActor.shared.seekToEntry(
                    sectionIndex: savedSectionIndex,
                    entryIndex: savedEntryIndex
                )
                debugLog("[EbookPlayerViewModel] Restored position to section \(savedSectionIndex), entry \(savedEntryIndex)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to restore position: \(error)")
            }
        }
    }

    private func navigateToCurrentActorPosition(bridge: WebViewCommsBridge) async {
        guard let syncData = await SMILPlayerActor.shared.getBackgroundSyncData() else {
            debugLog("[EbookPlayerViewModel] No sync data from actor, falling back to default")
            progressManager?.handleBookStructureReady()
            return
        }

        debugLog("[EbookPlayerViewModel] Navigating to actor position: section=\(syncData.sectionIndex), href=\(syncData.href), fragment=\(syncData.fragment)")

        do {
            let hrefWithFragment = "\(syncData.href)#\(syncData.fragment)"
            try await bridge.sendJsGoToHrefCommand(href: hrefWithFragment)

            progressManager?.selectedChapterId = syncData.sectionIndex
            progressManager?.hasPerformedInitialSeek = true

            debugLog("[EbookPlayerViewModel] Successfully joined session at section \(syncData.sectionIndex)")
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to navigate to actor position: \(error)")
            progressManager?.handleBookStructureReady()
        }
    }

    func handleOnDisappear() {
        debugLog("[EbookPlayerViewModel] View disappearing")
        debugLog("[EbookPlayerViewModel] Window closing")

        Task { @MainActor in
            await mediaOverlayManager?.cleanup()
            await progressManager?.cleanup()
            await SMILPlayerActor.shared.cleanup()
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .active:
                Task { @MainActor in
                    await progressManager?.handleResume()
                    await SMILPlayerActor.shared.reconcilePositionFromPlayer()
                    if let syncData = await SMILPlayerActor.shared.getBackgroundSyncData() {
                        debugLog(
                            "[EbookPlayerViewModel] Resuming from background - syncing view to audio position"
                        )
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
            debugLog(
                "[EbookPlayerViewModel] Recovery mode - updating existing managers with new bridge"
            )
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

    private func setupBridgeCallbacks(_ bridge: WebViewCommsBridge, initialColorScheme: ColorScheme)
    {

        bridge.onBookStructureReady = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                debugLog("[EbookPlayerViewModel] WebView ready (BookStructureReady)")

                #if os(iOS)
                let isRecovering = self.recoveryManager?.isInRecovery == true
                #else
                let isRecovering = false
                #endif

                if self.bookData?.category == .synced, let loadingTask = self.nativeLoadingTask {
                    debugLog("[EbookPlayerViewModel] Waiting for native SMIL parsing to complete...")
                    await loadingTask.value
                    debugLog("[EbookPlayerViewModel] Native SMIL parsing complete")
                }

                let useNativeStructure = self.bookData?.category == .synced && !self.bookStructure.isEmpty
                let structureToUse = useNativeStructure ? self.bookStructure : message.sections

                if !useNativeStructure {
                    self.bookStructure = message.sections
                }

                self.progressManager?.bookStructure = structureToUse

                if isRecovering {
                    #if os(iOS)
                    debugLog(
                        "[EbookPlayerViewModel] Recovery mode - reusing existing MOM/SMILPlayerActor"
                    )
                    self.mediaOverlayManager?.commsBridge = bridge
                    _ = self.recoveryManager?.handleBookStructureReadyIfRecovering()
                    #endif
                } else {
                    let hasMediaOverlay = structureToUse.contains { !$0.mediaOverlay.isEmpty }

                    if hasMediaOverlay {
                        let currentBookId = self.bookData?.metadata.uuid ?? "unknown"
                        let manager = MediaOverlayManager(
                            bookStructure: structureToUse,
                            bookId: currentBookId,
                            bridge: bridge,
                            reloadBookIntoActor: { [weak self] in
                                await self?.reloadBookIntoActor()
                            }
                        )
                        debugLog(
                            "[EbookPlayerViewModel] Book has media overlay - MediaOverlayManager created (native structure: \(useNativeStructure))"
                        )
                        manager.setPlaybackRate(self.settingsVM.defaultPlaybackSpeed)
                        self.mediaOverlayManager = manager
                        self.hasAudioNarration = true
                        self.progressManager?.mediaOverlayManager = manager
                        manager.progressManager = self.progressManager
                    } else {
                        debugLog("[EbookPlayerViewModel] Book has no media overlay")
                        self.mediaOverlayManager = nil
                        self.hasAudioNarration = false
                        self.progressManager?.mediaOverlayManager = nil
                    }

                    if self.isJoiningExistingSession {
                        debugLog("[EbookPlayerViewModel] Joining session - navigating to current actor position")
                        await self.navigateToCurrentActorPosition(bridge: bridge)
                    } else {
                        self.progressManager?.handleBookStructureReady()
                    }

                    Task { @MainActor in
                        let syncInterval = await SettingsActor.shared.config.sync
                            .progressSyncIntervalSeconds
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
