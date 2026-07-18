#if os(iOS) || os(macOS)
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
    var tocEntries: [TocEntry] = []
    private var userSelectedTocId: String? = nil
    var mediaOverlayManager: MediaOverlayManager? = nil
    var progressManager: EbookProgressManager? = nil
    var styleManager: ReaderStyleManager? = nil
    var searchManager: EbookSearchManager? = nil
    var extractedEbookPath: URL? = nil
    var ebookFileFormat: EbookFileFormat = .epub
    var comicPageURLs: [URL] = []
    private var nativeLoadingTask: Task<Void, Never>? = nil
    #if os(iOS)
    private(set) var recoveryManager: WebViewRecoveryManager?
    #endif

    var chapterList: [ChapterItem] {
        if !tocEntries.isEmpty {
            return tocEntries.enumerated().map { idx, entry in
                ChapterItem(
                    id: "toc-\(idx)",
                    label: entry.label,
                    href: entry.href,
                    level: entry.level,
                )
            }
        }
        return bookStructure.filter { $0.label != nil }.map {
            ChapterItem(
                id: $0.id,
                label: $0.label ?? "Untitled",
                href: $0.id,
                level: $0.level ?? 0,
            )
        }
    }

    var hasAudioNarration: Bool = false

    var isComicBook: Bool {
        ebookFileFormat == .cbz
    }

    private var _sidebarInitialized = false
    #if os(macOS)
    var showChapterSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showChapterSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Chapter sidebar changed: \(oldValue) -> \(showChapterSidebar), saving..."
                )
                UserDefaults.standard.set(
                    showChapterSidebar,
                    forKey: "EbookPlayerShowChapterSidebar",
                )
            }
        }
    }
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Sidebar changed: \(oldValue) -> \(showAudioSidebar), saving..."
                )
                UserDefaults.standard.set(showAudioSidebar, forKey: "EbookPlayerShowAudioSidebar")
            }
        }
    }
    var isTitleBarHovered = false
    #else
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar {
                UserDefaults.standard.set(
                    showAudioSidebar,
                    forKey: "EbookPlayerShowAudioSidebarIOS",
                )
            }
        }
    }
    var showAudioSheet = false
    var isReadingBarVisible = true
    var isTopBarVisible = true
    var collapseCardTrigger = 0
    #endif
    private var isAudioPlayerExpanded = false
    private var isReaderSceneActive = true
    var showCustomizePopover = false
    var commsBridge: WebViewCommsBridge? = nil
    var playbackProgressMessage: Any? = nil

    var chapterProgressBinding: Binding<Double> {
        Binding(
            get: {
                if self.isComicBook {
                    return self.progressManager?.bookFraction ?? 0.0
                }
                return self.progressManager?.chapterSeekBarValue ?? 0.0
            },
            set: { newValue in
                if self.isComicBook {
                    self.progressManager?.handleNativeProgressSeek(newValue)
                } else {
                    self.progressManager?.handleUserProgressSeek(newValue)
                }
            },
        )
    }

    var selectedChapterHref: String? {
        guard let index = progressManager?.selectedChapterId else { return nil }
        if !tocEntries.isEmpty {
            // If user explicitly clicked a toc entry, and it still matches the current section, use it
            if let userSelected = userSelectedTocId,
                userSelected.hasPrefix("toc-"),
                let idx = Int(userSelected.dropFirst(4)),
                idx < tocEntries.count,
                tocEntries[idx].sectionIndex == index
            {
                return userSelected
            }
            // Otherwise find the first toc entry that matches this section index
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex == index {
                    return "toc-\(offset)"
                }
            }
            // No exact match - find the last entry with a lower section index
            var lastOffset: Int? = nil
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex < index {
                    lastOffset = offset
                }
            }
            if let offset = lastOffset {
                return "toc-\(offset)"
            }
            return nil
        }
        return bookStructure[safe: index]?.id
    }

    var sleepTimerActive = false
    var sleepTimerRemaining: TimeInterval? = nil
    var sleepTimerType: Any? = nil
    var lastRestartTime: Date? = nil
    var isJoiningExistingSession = false
    var showKeybindingsPopover = false
    var showSearchPanel = false
    var pendingSearchReveal = false
    var showTranslation = false
    var translationText = ""
    var showBookmarksPanel = false
    var bookmarksPanelInitialTab: BookmarksPanel.Tab = .bookmarks
    var highlights: [Highlight] = []
    var pendingSelection: TextSelectionMessage? = nil
    var pendingEditHighlight: Highlight? = nil

    var showServerPositionDialog = false
    var pendingServerPosition: IncomingServerPosition? = nil
    private var incomingPositionObserverId: UUID? = nil

    var serverPositionDescription: String {
        guard let position = pendingServerPosition else {
            return "Another device has synced a more recent reading position."
        }
        let locator = position.locator
        var details: [String] = []
        if let title = locator.title {
            details.append(title)
        }
        if let prog = locator.locations?.totalProgression {
            details.append("\(Int(prog * 100))%")
        }
        let locationStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return
            "Another device has synced a more recent reading position\(locationStr). Would you like to go to that location?"
    }

    var bookmarks: [Highlight] {
        highlights.filter { $0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    var coloredHighlights: [Highlight] {
        highlights.filter { !$0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    init(bookData: PlayerBookData?, settingsVM: SettingsViewModel = SettingsViewModel()) {
        self.bookData = bookData
        self.settingsVM = settingsVM
        #if os(macOS)
        let savedAudioSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowAudioSidebar") as? Bool
        self.showAudioSidebar = savedAudioSidebarState ?? true
        let savedChapterSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowChapterSidebar") as? Bool
        self.showChapterSidebar = savedChapterSidebarState ?? false
        debugLog(
            "[EbookPlayerViewModel] Init - audio sidebar: \(self.showAudioSidebar), chapter sidebar: \(self.showChapterSidebar)"
        )
        #else
        self.showAudioSidebar =
            UserDefaults.standard.object(forKey: "EbookPlayerShowAudioSidebarIOS") as? Bool ?? false
        #endif
        self._sidebarInitialized = true
    }

    func handleChapterSelection(_ chapter: ChapterItem) {
        debugLog(
            "[TOC-DEBUG] handleChapterSelection: id=\(chapter.id) label=\"\(chapter.label)\" href=\"\(chapter.href)\" level=\(chapter.level)"
        )
        userSelectedTocId = chapter.id
        if isComicBook, let index = Int(chapter.href) ?? Int(chapter.id) {
            progressManager?.handleNativePageSelected(index)
            return
        }
        if !tocEntries.isEmpty, chapter.id.hasPrefix("toc-"),
            let idx = Int(chapter.id.dropFirst(4)), idx < tocEntries.count
        {
            let entry = tocEntries[idx]
            let fragment = entry.href.components(separatedBy: "#").dropFirst().first

            if let fragment, let sectionId = bookStructure[safe: entry.sectionIndex]?.id {
                let fullHref = "\(sectionId)#\(fragment)"
                debugLog("[TOC-DEBUG] -> EPM href navigation to \(fullHref)")
                progressManager?.handleUserChapterSelectedWithHref(
                    entry.sectionIndex,
                    href: fullHref,
                )
            } else {
                debugLog(
                    "[TOC-DEBUG] -> EPM section navigation to sectionIndex=\(entry.sectionIndex)"
                )
                progressManager?.handleUserChapterSelected(entry.sectionIndex)
            }
            return
        }
        debugLog("[TOC-DEBUG] -> falling back to href-based lookup")
        handleChapterSelectionByHref(chapter.href)
    }

    func handleChapterSelectionByHref(_ href: String) {
        debugLog("[EbookPlayerViewModel] Chapter selected by href: \(href)")

        guard let chapterIndex = findSectionIndex(for: href, in: bookStructure) else {
            debugLog("[EbookPlayerViewModel] Chapter not found for href: \(href)")
            return
        }

        debugLog("[EbookPlayerViewModel] Found chapter at index: \(chapterIndex)")
        progressManager?.handleUserChapterSelected(chapterIndex)
    }

    func handlePrevChapter() {
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavLeft()
            return
        }
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
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavRight()
            return
        }
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

    func handleAudioPlayerExpandedChange(_ isExpanded: Bool) {
        guard isAudioPlayerExpanded != isExpanded else { return }
        isAudioPlayerExpanded = isExpanded
        applyActivePlayback()
    }

    private var activePlaybackRole: PlaybackSpeedRole {
        #if os(macOS)
        .readaloud
        #else
        PlaybackRatePolicy.activeRole(
            isReaderSceneActive: isReaderSceneActive,
            isPlayerExpanded: isAudioPlayerExpanded,
        )
        #endif
    }

    var activePlaybackRate: Double {
        settingsVM.playback.playbackSpeed(for: activePlaybackRole)
    }

    func applyActivePlayback() {
        let role = activePlaybackRole
        let rate = settingsVM.playback.playbackSpeed(for: role)
        debugLog(
            "[EbookPlayerViewModel] Applying \(role == .readaloud ? "read-aloud" : "listening") rate \(rate)"
        )
        if let mediaOverlayManager {
            mediaOverlayManager.setPlaybackRate(rate)
        } else if let bookID = bookData?.metadata.id {
            Task {
                await SMILPlayerActor.shared.setPlaybackRate(rate, ifLoadedBookID: bookID)
            }
        }
    }

    func handleVolumeChange(_ newVolume: Double) {
        debugLog("[EbookPlayerViewModel] Received volume change to \(newVolume)")
        settingsVM.defaultVolume = newVolume
        mediaOverlayManager?.setVolume(newVolume)
        settingsVM.save()
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
        if isComicBook {
            progressManager?.handleNativeProgressSeek(fraction)
        } else {
            progressManager?.handleUserProgressSeek(fraction)
        }
    }

    func handleColorSchemeChange(_ colorScheme: ColorScheme) {
        settingsVM.applyActiveTheme(for: colorScheme)
        styleManager?.handleColorSchemeChange(colorScheme)
    }

    func handleAppBackgrounding() async {
        debugLog(
            "[EbookPlayerViewModel] App backgrounding - syncing progress (audio continues in background)"
        )

        #if os(iOS)
        isReaderSceneActive = false
        applyActivePlayback()
        #endif
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
            }
            debugLog("[EbookPlayerViewModel] Preparing local ebook file")
            let needsNativeAudio = data.category == .synced
            nativeLoadingTask = Task { @MainActor in
                do {
                    let prepStarted = CFAbsoluteTimeGetCurrent()
                    let prepared = try await BookServiceActor.shared.prepareEbookForReading(
                        bookID: data.metadata.id,
                        category: data.category,
                    )
                    let afterPrepare = CFAbsoluteTimeGetCurrent()
                    debugLog(
                        "[RestoreTrace][BookOpen] prepareEbookForReading deltaMs=\(String(format: "%.1f", (afterPrepare - prepStarted) * 1000))"
                    )
                    self.ebookFileFormat = EbookFileFormat(fileURL: prepared.originalURL)
                    self.extractedEbookPath = prepared.readerURL
                    debugLog(
                        "[EbookPlayerViewModel] EPUB prepared for loading: \(prepared.readerURL.path)"
                    )

                    if self.ebookFileFormat == .cbz {
                        self.prepareComicPages(from: prepared.readerURL)
                    } else if needsNativeAudio {
                        await loadBookIntoActor(epubPath: prepared.originalURL)
                    } else {
                        await parseNativeTocEntries(epubPath: prepared.originalURL)
                    }
                    debugLog(
                        "[RestoreTrace][BookOpen] \(needsNativeAudio ? "loadBookIntoActor" : "parseNativeTocEntries") deltaMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - afterPrepare) * 1000))"
                    )
                } catch {
                    debugLog("[EbookPlayerViewModel] Failed to prepare EPUB: \(error)")
                }
            }

            registerIncomingPositionObserver(bookId: data.metadata.id)
        }
    }

    private func prepareComicPages(from extractedDirectory: URL) {
        let urls = Self.comicImageURLs(in: extractedDirectory)
        comicPageURLs = urls
        bookStructure = urls.enumerated().map { index, url in
            SectionInfo(
                index: index,
                id: "\(index)",
                label: "Page \(index + 1)",
                level: 0,
                mediaOverlay: [],
            )
        }
        tocEntries = []
        hasAudioNarration = false
        mediaOverlayManager = nil
        searchManager = nil
        styleManager = nil
        progressManager = EbookProgressManager(
            bridge: nil,
            settingsVM: settingsVM,
            bookID: bookData?.metadata.id,
            initialLocator: bookData?.metadata.position?.locator,
        )
        progressManager?.bookStructure = bookStructure
        progressManager?.bookTitle = bookData?.metadata.title
        progressManager?.bookAuthor = bookData?.metadata.authors?.first?.name
        progressManager?.handleNativeBookStructureReady(pageCount: urls.count)

        Task { @MainActor in
            let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
            self.progressManager?.startPeriodicSync(syncInterval: syncInterval)
        }
    }

    private static func comicImageURLs(in directory: URL) -> [URL] {
        let allowedExtensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "jxl", "avif",
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
            )
        else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == false ? nil : url
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func handleComicPageSelected(_ index: Int) {
        userSelectedTocId = nil
        progressManager?.handleNativePageSelected(index)
    }

    private func registerIncomingPositionObserver(bookId: BookID) {
        Task {
            incomingPositionObserverId = await ProgressSyncActor.shared.addIncomingPositionObserver(
                for: bookId
            ) { [weak self] position in
                guard let self else { return }

                if self.settingsVM.autoSyncToNewerServerPosition {
                    Task {
                        await self.navigateToServerPosition(position.locator)
                    }
                } else {
                    self.pendingServerPosition = position
                    self.showServerPositionDialog = true
                }
            }
            debugLog("[EbookPlayerViewModel] Registered incoming position observer for \(bookId)")
        }
    }

    func navigateToServerPosition(_ locator: BookLocator) async {
        debugLog("[EbookPlayerViewModel] Navigating to server position: \(locator.href)")
        progressManager?.handleServerPositionUpdate(locator)
    }

    func acceptServerPosition() {
        guard let position = pendingServerPosition else { return }
        Task {
            await navigateToServerPosition(position.locator)
        }
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    func declineServerPosition() {
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    private func parseNativeTocEntries(epubPath: URL) async {
        do {
            let result = try SMILParser.parseEPUB(at: epubPath)
            self.tocEntries = result.tocEntries
            self.bookStructure = result.sections
            debugLog(
                "[EbookPlayerViewModel] Parsed \(result.tocEntries.count) native TOC entries for ebook-only mode"
            )
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to parse native TOC: \(error)")
        }
    }

    private func loadBookIntoActor(epubPath: URL) async {
        guard let currentBookID = bookData?.metadata.id else {
            debugLog("[EbookPlayerViewModel] Cannot load SMIL actor without book identity")
            return
        }
        let loadedBookID = await SMILPlayerActor.shared.getLoadedBookID()
        let currentState = await SMILPlayerActor.shared.getCurrentState()
        let isPlaying = currentState?.isPlaying ?? false

        if loadedBookID == currentBookID && isPlaying {
            debugLog(
                "[EbookPlayerViewModel] Book already loaded and playing in SMILPlayerActor, joining existing session"
            )
            isJoiningExistingSession = true
            let nativeStructure = await SMILPlayerActor.shared.getBookStructure()
            self.bookStructure = nativeStructure
            self.tocEntries = await SMILPlayerActor.shared.getTocEntries()
            await SMILPlayerActor.shared.setPlaybackRate(
                activePlaybackRate,
                ifLoadedBookID: currentBookID,
            )
            debugLog("[EbookPlayerViewModel] Joined session with \(nativeStructure.count) sections")
            return
        }

        if loadedBookID == currentBookID {
            debugLog(
                "[EbookPlayerViewModel] Book loaded but paused, reloading fresh from PSA"
            )
        }

        if await SMILPlayerActor.shared.activeAudioPlayer == .audiobook {
            await AudiobookActor.shared.cleanup()
            debugLog("[EbookPlayerViewModel] Cleaned up AudiobookActor before loading readaloud")
        }

        do {
            try await SMILPlayerActor.shared.loadBook(
                epubPath: epubPath,
                bookID: currentBookID,
                title: bookData?.metadata.title,
                author: bookData?.metadata.authors?.first?.name,
            )
            await SMILPlayerActor.shared.setPlaybackRate(activePlaybackRate)
            await SMILPlayerActor.shared.setVolume(settingsVM.defaultVolume)

            let nativeStructure = await SMILPlayerActor.shared.getBookStructure()
            self.bookStructure = nativeStructure
            self.tocEntries = await SMILPlayerActor.shared.getTocEntries()
            debugLog(
                "[EbookPlayerViewModel] Native book structure loaded: \(nativeStructure.count) sections"
            )

            #if os(iOS)
            if let metadata = bookData?.metadata {
                if let coverData = await BookServiceActor.shared.cachedCoverData(
                    for: metadata.id,
                    audio: false,
                ) {
                    await SMILPlayerActor.shared.setCoverImage(coverData)
                    debugLog("[EbookPlayerViewModel] Cover image set on SMILPlayerActor")
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
                    entryIndex: savedEntryIndex,
                )
                debugLog(
                    "[EbookPlayerViewModel] Restored position to section \(savedSectionIndex), entry \(savedEntryIndex)"
                )
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

        debugLog(
            "[EbookPlayerViewModel] Navigating to actor position: section=\(syncData.sectionIndex), href=\(syncData.href), fragment=\(syncData.fragment)"
        )

        do {
            let hrefWithFragment = "\(syncData.href)#\(syncData.fragment)"
            try await bridge.sendJsGoToHrefCommand(href: hrefWithFragment)

            progressManager?.selectedChapterId = syncData.sectionIndex
            progressManager?.hasPerformedInitialSeek = true

            debugLog(
                "[EbookPlayerViewModel] Successfully joined session at section \(syncData.sectionIndex)"
            )
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to navigate to actor position: \(error)")
            progressManager?.handleBookStructureReady()
        }
    }

    func handleOnDisappear(cleanupPlayback: Bool = true) {
        debugLog("[EbookPlayerViewModel] View disappearing")
        debugLog("[EbookPlayerViewModel] Window closing")

        if let id = incomingPositionObserverId {
            Task {
                await ProgressSyncActor.shared.removeIncomingPositionObserver(id: id)
            }
            incomingPositionObserverId = nil
        }

        guard cleanupPlayback else {
            debugLog("[EbookPlayerViewModel] Background disappear - preserving SMIL playback")
            return
        }

        Task { @MainActor in
            await mediaOverlayManager?.cleanup()
            await progressManager?.cleanup()
            debugLog("[EbookPlayerViewModel] onDisappear: calling SMILPlayerActor.cleanup()")
            await SMILPlayerActor.shared.cleanup()
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .active:
                #if os(iOS)
                isReaderSceneActive = true
                applyActivePlayback()
                #endif
                Task { @MainActor in
                    await progressManager?.handleResume()

                    mediaOverlayManager?.isInBackground = false
                    let audioPlayedWhileBackgrounded =
                        mediaOverlayManager?.backgroundAudioPlayed ?? false
                    if audioPlayedWhileBackgrounded {
                        await SMILPlayerActor.shared.reconcilePositionFromPlayer()
                        if let syncData = await SMILPlayerActor.shared.getBackgroundSyncData() {
                            debugLog(
                                "[EbookPlayerViewModel] Resuming from background - syncing view to audio position"
                            )
                            await progressManager?.handleBackgroundSyncHandoff(syncData)
                        }
                    }
                    mediaOverlayManager?.backgroundAudioPlayed = false
                }
            case .background:
                debugLog("[EbookPlayerViewModel] Entering background - audio continues natively")
                #if os(iOS)
                isReaderSceneActive = false
                applyActivePlayback()
                #endif
                Task { @MainActor in
                    mediaOverlayManager?.isInBackground = true
                    let wasPlaying =
                        await SMILPlayerActor.shared.getCurrentState()?.isPlaying ?? false
                    if wasPlaying {
                        mediaOverlayManager?.backgroundAudioPlayed = true
                    }
                }
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
            settingsVM: settingsVM,
            bookID: bookData?.metadata.id,
            initialLocator: bookData?.metadata.position?.locator,
        )

        if let metadata = bookData?.metadata {
            progressManager?.bookTitle = metadata.title
            progressManager?.bookAuthor = metadata.authors?.first?.name

            Task {
                if let coverData = await BookServiceActor.shared.cachedCoverData(
                    for: metadata.id,
                    audio: false,
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
            bridge: bridge,
        )

        setupBridgeCallbacks(bridge, initialColorScheme: initialColorScheme)
    }

    private func setupBridgeCallbacks(
        _ bridge: WebViewCommsBridge,
        initialColorScheme: ColorScheme,
    ) {

        bridge.onBookStructureReady = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                debugLog("[EbookPlayerViewModel] WebView ready (BookStructureReady)")

                #if os(iOS)
                let isRecovering = self.recoveryManager?.isInRecovery == true
                #else
                let isRecovering = false
                #endif

                if let loadingTask = self.nativeLoadingTask {
                    debugLog(
                        "[EbookPlayerViewModel] Waiting for native EPUB parsing to complete..."
                    )
                    await loadingTask.value
                    debugLog("[EbookPlayerViewModel] Native EPUB parsing complete")
                }

                let useNativeStructure = !self.bookStructure.isEmpty
                let structureToUse: [SectionInfo]

                if useNativeStructure {
                    structureToUse = self.bookStructure
                } else {
                    self.bookStructure = message.sections
                    structureToUse = message.sections
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
                        guard let currentBookID = self.bookData?.metadata.id else {
                            debugLog(
                                "[EbookPlayerViewModel] Cannot create media overlay manager without book identity"
                            )
                            return
                        }
                        let manager = MediaOverlayManager(
                            bookStructure: structureToUse,
                            bookID: currentBookID,
                            bridge: bridge,
                            settingsVM: self.settingsVM,
                            reloadBookIntoActor: { [weak self] in
                                await self?.reloadBookIntoActor()
                            },
                        )
                        debugLog(
                            "[EbookPlayerViewModel] Book has media overlay - MediaOverlayManager created (native structure: \(useNativeStructure))"
                        )
                        manager.setPlaybackRate(self.activePlaybackRate)
                        self.mediaOverlayManager = manager
                        self.hasAudioNarration = true
                        self.styleManager?.setReadaloudModeAvailable(true)
                        self.progressManager?.mediaOverlayManager = manager
                        manager.progressManager = self.progressManager
                    } else {
                        debugLog("[EbookPlayerViewModel] Book has no media overlay")
                        self.mediaOverlayManager = nil
                        self.hasAudioNarration = false
                        self.styleManager?.setReadaloudModeAvailable(false)
                        self.progressManager?.mediaOverlayManager = nil
                    }

                    if self.isJoiningExistingSession {
                        debugLog(
                            "[EbookPlayerViewModel] Joining session - navigating to current actor position"
                        )
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

                self.settingsVM.applyActiveTheme(for: initialColorScheme)
                self.styleManager?.sendInitialStyles(colorScheme: initialColorScheme)

                await self.loadHighlights()
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
                self.userSelectedTocId = nil
                self.progressManager?.handleUserNavSwipeDetected(message)
            }
        }

        bridge.onMarginClickNav = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.userSelectedTocId = nil
                if message.direction == "left" {
                    self.progressManager?.handleUserNavLeft()
                } else {
                    self.progressManager?.handleUserNavRight()
                }
            }
        }

        bridge.onSentenceSkip = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                if message.direction == "previous" {
                    self.handlePrevSentence()
                } else {
                    self.handleNextSentence()
                }
            }
        }

        bridge.onMediaOverlaySeek = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.mediaOverlayManager?.handleSeekEvent(
                    sectionIndex: message.sectionIndex,
                    anchor: message.anchor,
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

        bridge.onTextSelected = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleTextSelectionComplete(message)
            }
        }

        bridge.onSelectionHighlight = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                let color = HighlightColor(rawValue: message.colorId)
                await self.addHighlight(from: message.selection, color: color)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightSetColor = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightSetColor(id: message.id, colorId: message.colorId)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightDelete = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightDelete(id: message.id)
            }
        }

        bridge.onHighlightEdit = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleHighlightEdit(id: message.id)
            }
        }

        bridge.onSelectionTranslate = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.translationText = text
                self.showTranslation = true
            }
        }

        bridge.onSelectionSearch = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.searchManager?.searchQuery = text
                #if os(macOS)
                // The search popover anchors to the toolbar magnifier, which is
                // hidden until the title bar reveals. Reveal it first; the panel
                // is presented once the toolbar is on-screen (handleTitleBarApplied).
                self.pendingSearchReveal = true
                #else
                self.showSearchPanel = true
                await self.searchManager?.startSearch(query: text)
                #endif
            }
        }
    }

    #if os(macOS)
    /// Defers the search popover until the toolbar anchor is on-screen, avoiding a flicker.
    func handleTitleBarApplied() {
        guard pendingSearchReveal, !showSearchPanel else { return }
        pendingSearchReveal = false
        showSearchPanel = true
        let query = searchManager?.searchQuery ?? ""
        Task { await searchManager?.startSearch(query: query) }
    }
    #endif

    /// Navigate to search result - view only, no audio sync
    func handleSearchResultNavigation(_ result: SearchResult) {
        Task { @MainActor in
            await searchManager?.navigateToResult(result)
        }
    }

    // MARK: - Highlights / Bookmarks

    func loadHighlights() async {
        guard let bookID = bookData?.metadata.id else { return }

        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        debugLog("[EbookPlayerViewModel] Loaded \(highlights.count) highlights for book \(bookID)")

        await sendHighlightsToJS()
    }

    func addHighlight(
        from selection: TextSelectionMessage,
        color: HighlightColor?,
        note: String? = nil,
    ) async {
        guard let bookID = bookData?.metadata.id else { return }

        let locator = BookLocator(
            href: selection.href,
            type: "application/xhtml+xml",
            title: selection.title,
            locations: BookLocator.Locations(
                fragments: [selection.cfi],
                progression: nil,
                position: nil,
                totalProgression: nil,
                cssSelector: selection.startCssSelector,
                partialCfi: selection.cfi,
                domRange: BookLocator.Locations.DomRange(
                    start: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.startCssSelector,
                        textNodeIndex: selection.startTextNodeIndex,
                        charOffset: selection.startCharOffset,
                    ),
                    end: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.endCssSelector,
                        textNodeIndex: selection.endTextNodeIndex,
                        charOffset: selection.endCharOffset,
                    ),
                ),
            ),
            text: BookLocator.Text(
                after: nil,
                before: nil,
                highlight: selection.text,
            ),
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: selection.text,
            color: color,
            note: note,
        )

        await BookmarkActor.shared.addHighlight(highlight)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        pendingSelection = nil

        await sendHighlightsToJS()

        debugLog("[EbookPlayerViewModel] Added highlight: isBookmark=\(highlight.isBookmark)")
    }

    func deleteHighlight(_ highlight: Highlight) async {
        guard let bookID = bookData?.metadata.id else { return }

        await BookmarkActor.shared.deleteHighlight(id: highlight.id, bookID: bookID)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        if let bridge = commsBridge {
            do {
                try await bridge.sendJsRemoveHighlight(id: highlight.id.uuidString)
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to remove highlight from JS: \(error)")
            }
        }

        debugLog("[EbookPlayerViewModel] Deleted highlight: \(highlight.id)")
    }

    func navigateToHighlight(_ highlight: Highlight) async {
        guard let bridge = commsBridge else { return }

        if let cfi = highlight.locator.locations?.partialCfi {
            do {
                try await bridge.sendJsGoToCFICommand(cfi: cfi)
                debugLog("[EbookPlayerViewModel] Navigated to highlight CFI: \(cfi)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        } else {
            var href = highlight.locator.href
            if let fragment = highlight.locator.locations?.fragments?.first {
                href = "\(href)#\(fragment)"
            }
            do {
                try await bridge.sendJsGoToHrefCommand(href: href)
                debugLog("[EbookPlayerViewModel] Navigated to highlight href: \(href)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        }
    }

    func refreshHighlightColors() async {
        await sendHighlightsToJS()
    }

    private func sendHighlightPaletteToJS() async {
        guard let bridge = commsBridge else { return }

        let entries = HighlightColor.allCases.map { color in
            HighlightPaletteEntry(
                id: color.rawValue,
                color: settingsVM.hexColor(for: color),
                label: settingsVM.label(for: color),
            )
        }

        let translateAvailable: Bool
        if #available(iOS 17.4, macOS 14.4, *) {
            translateAvailable = true
        } else {
            translateAvailable = false
        }

        do {
            try await bridge.sendJsSetHighlightPalette(entries)
            try await bridge.sendJsSetTranslateAvailable(translateAvailable)
            try await bridge.sendJsSetDefaultHighlightColor(lastUsedHighlightColorId)
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlight palette to JS: \(error)")
        }
    }

    private static let lastUsedHighlightColorKey = "lastUsedHighlightColorId"

    var lastUsedHighlightColorId: String {
        get {
            UserDefaults.standard.string(forKey: Self.lastUsedHighlightColorKey)
                ?? HighlightColor.allCases.first!.rawValue
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastUsedHighlightColorKey) }
    }

    private func rememberLastUsedColor(_ colorId: String) {
        guard HighlightColor(rawValue: colorId) != nil else { return }
        guard colorId != lastUsedHighlightColorId else { return }
        lastUsedHighlightColorId = colorId
        Task { try? await commsBridge?.sendJsSetDefaultHighlightColor(colorId) }
    }

    private func sendHighlightsToJS() async {
        guard let bridge = commsBridge else { return }

        await sendHighlightPaletteToJS()

        let coloredOnly = highlights.filter { !$0.isBookmark }
        let renderData = coloredOnly.compactMap { highlight -> HighlightRenderData? in
            guard let cfi = highlight.locator.locations?.partialCfi,
                let color = highlight.color
            else { return nil }

            guard
                let sectionIndex = findSectionIndex(
                    for: highlight.locator.href,
                    in: bookStructure,
                )
            else { return nil }

            return HighlightRenderData(
                id: highlight.id.uuidString,
                sectionIndex: sectionIndex,
                cfi: cfi,
                color: settingsVM.hexColor(for: color),
            )
        }

        do {
            try await bridge.sendJsRenderHighlights(renderData)
            debugLog("[EbookPlayerViewModel] Sent \(renderData.count) highlights to JS")
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlights to JS: \(error)")
        }
    }

    func handleTextSelectionComplete(_ message: TextSelectionMessage) {
        debugLog("[EbookPlayerViewModel] Text selection complete: \(message.text.prefix(50))...")
        pendingSelection = message
    }

    func handleHighlightSetColor(id: String, colorId: String) async {
        guard let bookID = bookData?.metadata.id,
            let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid }),
            let color = HighlightColor(rawValue: colorId)
        else { return }

        let updated = Highlight(
            id: existing.id,
            bookID: existing.bookID,
            locator: existing.locator,
            text: existing.text,
            color: color,
            note: existing.note,
            createdAt: existing.createdAt,
        )

        await BookmarkActor.shared.updateHighlight(updated)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        await sendHighlightsToJS()
    }

    func handleHighlightDelete(id: String) async {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        await deleteHighlight(existing)
    }

    func handleHighlightEdit(id: String) {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        pendingEditHighlight = existing
    }

    func saveEditedHighlight(_ original: Highlight, color: HighlightColor?, note: String?) async {
        guard let bookID = bookData?.metadata.id else { return }
        let updated = Highlight(
            id: original.id,
            bookID: original.bookID,
            locator: original.locator,
            text: original.text,
            color: color,
            note: note,
            createdAt: original.createdAt,
        )
        await BookmarkActor.shared.updateHighlight(updated)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        await sendHighlightsToJS()
        pendingEditHighlight = nil
    }

    func cancelPendingSelection() {
        pendingSelection = nil
    }

    func cancelPendingEdit() {
        pendingEditHighlight = nil
    }

    func addBookmarkAtCurrentPage() async {
        guard let bookID = bookData?.metadata.id else {
            debugLog("[EbookPlayerViewModel] Cannot add bookmark - missing book ID")
            return
        }

        guard let position = try? await commsBridge?.sendJsGetFirstVisiblePosition() else {
            debugLog(
                "[EbookPlayerViewModel] Cannot add bookmark - failed to get visible position from JS"
            )
            return
        }

        let locator = BookLocator(
            href: position.href,
            type: "application/xhtml+xml",
            title: position.title,
            locations: BookLocator.Locations(
                fragments: position.elementId.map { [$0] },
                progression: nil,
                position: nil,
                totalProgression: progressManager?.bookFraction,
                cssSelector: nil,
                partialCfi: position.cfi,
                domRange: nil,
            ),
            text: nil,
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: position.text,
            color: nil,
            note: nil,
        )

        await BookmarkActor.shared.addHighlight(highlight)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        debugLog("[EbookPlayerViewModel] Added bookmark: \(position.text.prefix(50))...")
    }
}

#endif
