import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
extension Notification.Name {
    static let appWillResignActive = Notification.Name("appWillResignActive")
}
#endif

private struct PendingSelectionWrapper: Identifiable {
    let selection: TextSelectionMessage
    var id: String { selection.cfi }
}

public struct EbookPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var viewModel: EbookPlayerViewModel

    public init(bookData: PlayerBookData?) {
        self.viewModel = EbookPlayerViewModel(bookData: bookData)
    }

    public var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView(columnVisibility: $viewModel.columnVisibility) {
                EbookChapterSidebar(
                    selectedChapterId: viewModel.uiSelectedChapterIdBinding,
                    bookStructure: viewModel.bookStructure,
                    onChapterSelected: { _ in }
                )
            } detail: {
                readerLayout
            }
            #else
            readerLayout
            #endif
        }
        .background(readerBackgroundColor)
        #if os(iOS)
        .statusBarHidden(!viewModel.isTopBarVisible)
        .persistentSystemOverlays(viewModel.isTopBarVisible ? .automatic : .hidden)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onReceive(NotificationCenter.default.publisher(for: .appWillResignActive)) { _ in
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid

            backgroundTask = UIApplication.shared.beginBackgroundTask {
                debugLog("[EbookPlayerView] Background task expiring - cleaning up")
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }

            Task {
                await viewModel.handleAppBackgrounding()

                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
        }
        #else
        .onKeyPress(.leftArrow) {
            viewModel.progressManager?.handleUserNavLeft()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.progressManager?.handleUserNavRight()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.handlePrevSentence()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.handleNextSentence()
            return .handled
        }
        .onKeyPress(.space) {
            Task { await viewModel.progressManager?.togglePlaying() }
            return .handled
        }
        .toolbar {
            EbookPlayerToolbar(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            Color.clear
            .frame(height: 60)
            .contentShape(Rectangle())
            .ignoresSafeArea(edges: .top)
            .onHover { hovering in
                if viewModel.isTitleBarHovered != hovering {
                    viewModel.isTitleBarHovered = hovering
                }
            }
        }
        .background(
            TitleBarConfigurator(
                isTitleBarVisible: viewModel.isTitleBarHovered || viewModel.showCustomizePopover
                    || viewModel.showKeybindingsPopover || viewModel.showSearchPanel,
                windowTitle: viewModel.bookData?.metadata.title ?? "Ebook Reader"
            )
        )
        .navigationTitle(viewModel.bookData?.metadata.title ?? "Ebook Reader")
        #endif
        .onAppear {
            viewModel.handleOnAppear()
            #if os(iOS)
            CarPlayCoordinator.shared.isPlayerViewActive = true
            #endif
        }
        .onDisappear {
            viewModel.handleOnDisappear()
            #if os(iOS)
            CarPlayCoordinator.shared.isPlayerViewActive = false
            #endif
        }
        .onChange(of: colorScheme) { _, newScheme in
            viewModel.handleColorSchemeChange(newScheme)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
        .onChange(of: viewModel.settingsVM.highlightColorsHash) { _, _ in
            Task { await viewModel.refreshHighlightColors() }
        }
        #if os(iOS)
        .sheet(isPresented: $viewModel.showBookmarksPanel) {
            NavigationStack {
                BookmarksPanel(
                    bookmarks: viewModel.bookmarks,
                    highlights: viewModel.coloredHighlights,
                    onDismiss: { viewModel.showBookmarksPanel = false },
                    onNavigate: { highlight in
                        Task {
                            await viewModel.navigateToHighlight(highlight)
                            viewModel.showBookmarksPanel = false
                        }
                    },
                    onDelete: { highlight in
                        Task { await viewModel.deleteHighlight(highlight) }
                    },
                    onAddBookmark: {
                        Task { await viewModel.addBookmarkAtCurrentPage() }
                    },
                    initialTab: viewModel.bookmarksPanelInitialTab
                )
                .navigationTitle("Bookmarks & Highlights")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            viewModel.showBookmarksPanel = false
                        }
                    }
                }
            }
        }
        #endif
        .sheet(
            item: Binding(
                get: { viewModel.pendingSelection.map { PendingSelectionWrapper(selection: $0) } },
                set: { _ in viewModel.cancelPendingSelection() }
            )
        ) { wrapper in
            HighlightCreationSheet(
                selectedText: wrapper.selection.text,
                onSave: { color, note in
                    Task {
                        await viewModel.addHighlight(
                            from: wrapper.selection,
                            color: color,
                            note: note
                        )
                    }
                },
                onCancel: { viewModel.cancelPendingSelection() }
            )
        }
        .alert(
            "Server Has Newer Position",
            isPresented: $viewModel.showServerPositionDialog
        ) {
            Button("Go to New Position") {
                viewModel.acceptServerPosition()
            }
            Button("Stay Here", role: .cancel) {
                viewModel.declineServerPosition()
            }
        } message: {
            Text(viewModel.serverPositionDescription)
        }
    }

    private var readerLayout: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            readerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.showAudioSidebar {
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1)
                    .ignoresSafeArea()
                audiobookSidebar
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        #else
        readerContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var readerBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var separatorColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    #if os(iOS)
    private var webViewBackgroundColor: Color {
        if let bgColor = viewModel.settingsVM.backgroundColor, let color = Color(hex: bgColor) {
            return color
        }
        let defaultHex =
            colorScheme == .dark ? kDefaultBackgroundColorDark : kDefaultBackgroundColorLight
        return Color(hex: defaultHex) ?? .white
    }
    #endif

    private var readerContent: some View {
        ZStack(alignment: .bottom) {
            #if os(iOS)
            webViewBackgroundColor
                .ignoresSafeArea(.all)
            #endif

            ZStack {
                if let ebookPath = viewModel.extractedEbookPath {
                    #if os(iOS)
                    AnyView(
                        EbookPlayerWebView(
                            ebookPath: ebookPath,
                            commsBridge: $viewModel.commsBridge,
                            onBridgeReady: { bridge in
                                viewModel.installBridgeHandlers(
                                    bridge,
                                    initialColorScheme: colorScheme
                                )
                            },
                            onContentPurged: {
                                viewModel.recoveryManager?.handleContentPurged()
                            }
                        )
                    )
                    .ignoresSafeArea(.all)
                    #else
                    AnyView(
                        EbookPlayerWebView(
                            ebookPath: ebookPath,
                            commsBridge: $viewModel.commsBridge,
                            onBridgeReady: { bridge in
                                viewModel.installBridgeHandlers(
                                    bridge,
                                    initialColorScheme: colorScheme
                                )
                            }
                        )
                    )
                    #endif
                } else {
                    ProgressView("Loading book...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            #if os(iOS)
            let alwaysShowMini = viewModel.settingsVM.alwaysShowMiniPlayer
            let shouldShowStatsOverlay =
                !viewModel.showAudioSidebar && !viewModel.isTopBarVisible

            if shouldShowStatsOverlay {
                EbookOverlayIos(
                    showProgress: viewModel.settingsVM.showProgress,
                    showTimeRemainingInBook: viewModel.settingsVM.showTimeRemainingInBook,
                    showTimeRemainingInChapter: viewModel.settingsVM.showTimeRemainingInChapter,
                    showPageNumber: viewModel.settingsVM.showPageNumber,
                    showSkipBackward: viewModel.settingsVM.showOverlaySkipBackward,
                    showSkipForward: viewModel.settingsVM.showOverlaySkipForward,
                    overlayTransparency: viewModel.settingsVM.overlayTransparency,
                    bookFraction: viewModel.progressManager?.bookFraction,
                    bookTimeRemaining: viewModel.mediaOverlayManager?.bookTimeRemaining,
                    chapterTimeRemaining: viewModel.mediaOverlayManager?.chapterTimeRemaining,
                    currentPage: viewModel.progressManager?.chapterCurrentPage,
                    totalPages: viewModel.progressManager?.chapterTotalPages,
                    isPlaying: viewModel.mediaOverlayManager?.isPlaying ?? false,
                    hasAudioNarration: viewModel.hasAudioNarration,
                    positionAtTop: alwaysShowMini,
                    onSkipBackward: {
                        viewModel.handlePrevSentence()
                    },
                    onTogglePlaying: {
                        Task { await viewModel.progressManager?.togglePlaying() }
                    },
                    onSkipForward: {
                        viewModel.handleNextSentence()
                    }
                )
                .transition(.opacity)
            }

            if viewModel.isTopBarVisible {
                EbookPlayerTopToolbar(
                    hasAudioNarration: viewModel.hasAudioNarration,
                    playbackSpeed: viewModel.settingsVM.defaultPlaybackSpeed,
                    chapters: viewModel.chapterList,
                    selectedChapterId: viewModel.selectedChapterHref,
                    isSynced: viewModel.settingsVM.lockViewToAudio,
                    sleepTimerActive: viewModel.mediaOverlayManager?.sleepTimerActive ?? false,
                    sleepTimerRemaining: viewModel.mediaOverlayManager?.sleepTimerRemaining,
                    sleepTimerType: viewModel.mediaOverlayManager?.sleepTimerType,
                    showCustomizePopover: $viewModel.showCustomizePopover,
                    showSearchSheet: $viewModel.showSearchPanel,
                    showBookmarksPanel: $viewModel.showBookmarksPanel,
                    searchManager: viewModel.searchManager,
                    onDismiss: { dismiss() },
                    onChapterSelected: viewModel.handleChapterSelectionByHref,
                    onSyncToggle: { enabled in
                        viewModel.settingsVM.lockViewToAudio = enabled
                        Task { try? await viewModel.settingsVM.save() }
                    },
                    onSearchResultSelected: viewModel.handleSearchResultNavigation,
                    onSleepTimerStart: viewModel.handleSleepTimerStart,
                    onSleepTimerCancel: viewModel.handleSleepTimerCancel,
                    settingsVM: viewModel.settingsVM
                )
                .transition(.opacity)
            }

            draggableAudioCard

            playbackProgressBar
            #else
            let shouldShowBar = viewModel.settingsVM.enableReadingBar && !viewModel.showAudioSidebar

            if shouldShowBar {
                readingBottomBar
            }
            #endif
        }
    }

    #if os(iOS)
    private var safeAreaInsets: EdgeInsets {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first
        else {
            return EdgeInsets()
        }
        return EdgeInsets(
            top: window.safeAreaInsets.top,
            leading: window.safeAreaInsets.left,
            bottom: window.safeAreaInsets.bottom,
            trailing: window.safeAreaInsets.right
        )
    }

    @ViewBuilder
    private var draggableAudioCard: some View {
        let pm = viewModel.progressManager
        let mom = viewModel.mediaOverlayManager
        let currentChapterTitle = pm?.selectedChapterId.flatMap { index in
            viewModel.bookStructure[safe: index]?.label
        }
        let alwaysShow = viewModel.settingsVM.alwaysShowMiniPlayer
        let isPresentedBinding = Binding(
            get: { alwaysShow || self.viewModel.isReadingBarVisible },
            set: { newValue in
                if !alwaysShow {
                    self.viewModel.isReadingBarVisible = newValue
                }
            }
        )

        DraggableAudioCard(
            isPresented: isPresentedBinding,
            alwaysShow: alwaysShow,
            collapseTrigger: viewModel.collapseCardTrigger,
            bookTitle: viewModel.bookData?.metadata.title,
            coverArt: viewModel.bookData?.coverArt,
            ebookCoverArt: viewModel.bookData?.ebookCoverArt,
            chapterTitle: currentChapterTitle,
            isPlaying: mom?.isPlaying ?? false,
            chapterProgress: viewModel.chapterProgressBinding.wrappedValue,
            chapterElapsedSeconds: mom?.chapterElapsedSeconds,
            chapterTotalSeconds: mom?.chapterTotalSeconds,
            bookTimeRemaining: mom?.bookTimeRemaining,
            playbackRate: mom?.playbackRate ?? viewModel.settingsVM.defaultPlaybackSpeed,
            hasAudioNarration: viewModel.hasAudioNarration,
            chapters: viewModel.chapterList,
            selectedChapterHref: viewModel.selectedChapterHref,
            sleepTimerActive: mom?.sleepTimerActive ?? false,
            sleepTimerRemaining: mom?.sleepTimerRemaining,
            sleepTimerType: mom?.sleepTimerType,
            onPlayPause: {
                Task { await pm?.togglePlaying() }
            },
            onSkipBackward: {
                viewModel.handlePrevSentence()
            },
            onSkipForward: {
                viewModel.handleNextSentence()
            },
            onPrevChapter: {
                viewModel.handlePrevChapter()
            },
            onNextChapter: {
                viewModel.handleNextChapter()
            },
            onProgressSeek: viewModel.handleProgressSeek,
            onPlaybackRateChange: viewModel.handlePlaybackRateChange,
            onChapterSelected: viewModel.handleChapterSelectionByHref,
            onSleepTimerStart: viewModel.handleSleepTimerStart,
            onSleepTimerCancel: viewModel.handleSleepTimerCancel,
            onDismiss: {
                viewModel.isReadingBarVisible = false
            },
            fullContent: {
                audiobookSidebar
            }
        )
    }

    private var playbackProgressBar: some View {
        let progress = viewModel.chapterProgressBinding.wrappedValue
        return GeometryReader { geometry in
            let inset = geometry.size.width * 0.1
            let availableWidth = geometry.size.width - (inset * 2)
            Color.gray
                .opacity(colorScheme == .dark ? 0.6 : 0.7)
                .frame(width: availableWidth * progress, height: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
        }
        .frame(height: 3)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }
    #endif

    private var readingBottomBar: some View {
        let pm = viewModel.progressManager
        let mom = viewModel.mediaOverlayManager
        let progressData = ProgressData(
            chapterLabel: pm?.selectedChapterId.flatMap { index in
                viewModel.bookStructure[safe: index]?.label
            },
            chapterCurrentPage: pm?.chapterCurrentPage,
            chapterTotalPages: pm?.chapterTotalPages,
            chapterCurrentSecondsAudio: mom?.chapterElapsedSeconds,
            chapterTotalSecondsAudio: mom?.chapterTotalSeconds,
            bookCurrentSecondsAudio: mom?.bookElapsedSeconds,
            bookTotalSecondsAudio: mom?.bookTotalSeconds,
            bookCurrentFraction: pm?.bookFraction
        )

        #if os(iOS)
        return AnyView(
            EbookBottomBarIos(
                bookTitle: viewModel.bookData?.metadata.title,
                coverArt: viewModel.bookData?.coverArt,
                progressData: progressData,
                playbackRate: mom?.playbackRate ?? viewModel.settingsVM.defaultPlaybackSpeed,
                isPlaying: mom?.isPlaying ?? false,
                hasAudioNarration: viewModel.hasAudioNarration,
                chapterProgress: viewModel.chapterProgressBinding,
                onShowAudioSheet: { viewModel.showAudioSheet = true },
                onPlayPause: {
                    Task { await pm?.togglePlaying() }
                },
                onProgressSeek: viewModel.handleProgressSeek
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        )
        #else
        let bgHex =
            viewModel.settingsVM.backgroundColor
            ?? (colorScheme == .dark ? kDefaultBackgroundColorDark : kDefaultBackgroundColorLight)
        let isLight = isLightColor(hex: bgHex)
        return AnyView(
            EbookOverlayMac(
                readingBarConfig: viewModel.settingsVM.readingBarConfig,
                progressData: progressData,
                isPlaying: mom?.isPlaying ?? false,
                playbackRate: mom?.playbackRate ?? viewModel.settingsVM.defaultPlaybackSpeed,
                isLightBackground: isLight,
                chapterProgress: viewModel.chapterProgressBinding,
                onPrevChapter: viewModel.handlePrevChapter,
                onSkipBackward: viewModel.handlePrevSentence,
                onPlayPause: {
                    Task { await pm?.togglePlaying() }
                },
                onSkipForward: viewModel.handleNextSentence,
                onNextChapter: viewModel.handleNextChapter,
                onProgressSeek: viewModel.handleProgressSeek
            )
            .ignoresSafeArea(edges: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        )
        #endif
    }

    private func sidebarToggleButton(
        isVisible: Bool,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Label {
                Text(accessibilityLabel)
            } icon: {
                Image(systemName: systemImage)
                    .symbolVariant(isVisible ? .fill : .none)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(accessibilityLabel)
        #endif
    }

    #if os(macOS)
    private func isLightColor(hex: String) -> Bool {
        guard let color = Color(hex: hex) else {
            return colorScheme == .light
        }
        let nsColor = NSColor(color)
        guard let converted = nsColor.usingColorSpace(.sRGB) else {
            return colorScheme == .light
        }
        let brightness =
            (converted.redComponent * 299 + converted.greenComponent * 587 + converted.blueComponent
                * 114) / 1000
        return brightness > 0.5
    }
    #endif

    private var audiobookSidebar: some View {
        let pm = viewModel.progressManager
        let mom = viewModel.mediaOverlayManager
        let currentChapterTitle = pm?.selectedChapterId.flatMap { index in
            viewModel.bookStructure[safe: index]?.label
        }

        let bookTitle = viewModel.bookData?.metadata.title ?? "Unknown Book"
        let bookAuthor = viewModel.bookData?.metadata.authors?.first?.name ?? "Unknown Author"
        let defaultChapterDuration: TimeInterval = TimeInterval((12 * 60) + 27)
        let defaultBookDuration: TimeInterval = TimeInterval((8 * 60 * 60) + (9 * 60))
        let chapterDuration = mom?.chapterTimeRemaining ?? defaultChapterDuration
        let totalRemaining = mom?.bookTimeRemaining ?? defaultBookDuration

        let readingMode: ReadingMode = viewModel.bookData?.category == .ebook ? .ebook : .readaloud

        let progressData = ProgressData(
            chapterLabel: currentChapterTitle,
            chapterCurrentPage: pm?.chapterCurrentPage,
            chapterTotalPages: pm?.chapterTotalPages,
            chapterCurrentSecondsAudio: mom?.chapterElapsedSeconds,
            chapterTotalSecondsAudio: mom?.chapterTotalSeconds,
            bookCurrentSecondsAudio: mom?.bookElapsedSeconds,
            bookTotalSecondsAudio: mom?.bookTotalSeconds,
            bookCurrentFraction: pm?.bookFraction
        )

        return ReadingSidebarView(
            bookData: viewModel.bookData,
            model: .init(
                title: bookTitle,
                author: bookAuthor,
                chapterTitle: currentChapterTitle ?? "(Untitled)",
                coverArt: viewModel.bookData?.coverArt,
                ebookCoverArt: viewModel.bookData?.ebookCoverArt,
                chapterDuration: chapterDuration,
                totalRemaining: totalRemaining,
                playbackRate: mom?.playbackRate ?? viewModel.settingsVM.defaultPlaybackSpeed,
                volume: mom?.volume ?? viewModel.settingsVM.defaultVolume,
                isPlaying: mom?.isPlaying ?? false,
                sleepTimerActive: mom?.sleepTimerActive ?? false,
                sleepTimerRemaining: mom?.sleepTimerRemaining,
                sleepTimerType: mom?.sleepTimerType
            ),
            mode: readingMode,
            chapterProgress: viewModel.chapterProgressBinding,
            chapters: viewModel.chapterList,
            progressData: progressData,
            onChapterSelected: { href in
                viewModel.handleChapterSelectionByHref(href)
            },
            onPrevChapter: {
                viewModel.handlePrevChapter()
            },
            onSkipBackward: {
                viewModel.handlePrevSentence()
            },
            onPlayPause: {
                Task { await viewModel.progressManager?.togglePlaying() }
            },
            onSkipForward: {
                viewModel.handleNextSentence()
            },
            onNextChapter: {
                viewModel.handleNextChapter()
            },
            onPlaybackRateChange: { rate in
                viewModel.handlePlaybackRateChange(rate)
            },
            onVolumeChange: { newVolume in
                viewModel.handleVolumeChange(newVolume)
            },
            onSleepTimerStart: { duration, type in
                viewModel.handleSleepTimerStart(duration, type)
            },
            onSleepTimerCancel: {
                viewModel.handleSleepTimerCancel()
            },
            onProgressSeek: { fraction in
                viewModel.handleProgressSeek(fraction)
            }
        )
        .frame(
            minWidth: 300,
            idealWidth: 320,
            maxWidth: 360,
            maxHeight: .infinity,
            alignment: .trailing
        )
    }
}

#if os(macOS)
private class TitleBarDoubleClickGestureRecognizer: NSClickGestureRecognizer {
    var titlebarHeight: CGFloat = 52
}

private struct TitleBarConfigurator: NSViewRepresentable {
    var isTitleBarVisible: Bool
    var windowTitle: String = "Ebook Reader"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        @MainActor @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let window = gesture.view?.window,
                let contentView = window.contentView,
                let themeFrame = contentView.superview
            else { return }

            let location = gesture.location(in: themeFrame)
            let titlebarHeight =
                (gesture as? TitleBarDoubleClickGestureRecognizer)?.titlebarHeight ?? 52
            let titlebarRect = NSRect(
                x: 0,
                y: themeFrame.bounds.height - titlebarHeight,
                width: themeFrame.bounds.width,
                height: titlebarHeight
            )

            if titlebarRect.contains(location) {
                window.zoom(nil)
            }
        }
    }

    private func configureWindow(for nsView: NSView, coordinator: Coordinator) {
        guard let window = nsView.window else { return }
        window.titleVisibility = .hidden
        window.title = windowTitle
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar?.isVisible = true

        installDoubleClickGesture(on: window, coordinator: coordinator)
        updateTitleBarVisibility(for: window)
    }

    private func installDoubleClickGesture(on window: NSWindow, coordinator: Coordinator) {
        guard let themeFrame = window.contentView?.superview else { return }

        let alreadyInstalled = themeFrame.gestureRecognizers.contains {
            $0 is TitleBarDoubleClickGestureRecognizer
        }
        guard !alreadyInstalled else { return }

        let gesture = TitleBarDoubleClickGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        gesture.numberOfClicksRequired = 2
        gesture.delaysPrimaryMouseButtonEvents = false

        if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
            gesture.titlebarHeight = titlebarView.frame.height + titlebarView.frame.origin.y
        }

        themeFrame.addGestureRecognizer(gesture)
    }

    private func updateTitleBarVisibility(for window: NSWindow) {
        let buttonTypes: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton,
        ]
        buttonTypes
            .compactMap { window.standardWindowButton($0) }
            .forEach { button in
                button.alphaValue = isTitleBarVisible ? 1 : 0
                button.isEnabled = isTitleBarVisible
            }

        if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
            titlebarView.alphaValue = isTitleBarVisible ? 1 : 0
            titlebarView.isHidden = false
        }

        if let toolbar = window.toolbar {
            for item in toolbar.items {
                if let view = item.view {
                    view.alphaValue = isTitleBarVisible ? 1 : 0
                    view.isHidden = false
                }
                item.isEnabled = isTitleBarVisible
            }
        }
    }
}
#endif

#if DEBUG
struct EbookPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        EbookPlayerView(bookData: nil)
            .frame(width: 1024, height: 768)
    }
}
#endif
