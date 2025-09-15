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
        .sheet(isPresented: $viewModel.showAudioSheet) {
            audiobookSidebar
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        .onAppear { viewModel.handleOnAppear() }
        .onDisappear { viewModel.handleOnDisappear() }
        .onChange(of: colorScheme) { _, newScheme in
            viewModel.handleColorSchemeChange(newScheme)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
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

    private var readerContent: some View {
        ZStack(alignment: .bottom) {
            #if os(iOS)
            Color(viewModel.settingsVM.backgroundColor.flatMap { Color(hex: $0) } ?? .white)
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
                                viewModel.installBridgeHandlers(bridge, initialColorScheme: colorScheme)
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
                                viewModel.installBridgeHandlers(bridge, initialColorScheme: colorScheme)
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
            let shouldShowBar = !viewModel.showAudioSidebar && viewModel.isReadingBarVisible
            let shouldShowStatsOverlay = !viewModel.showAudioSidebar && !viewModel.isReadingBarVisible
            #else
            let shouldShowBar = viewModel.settingsVM.enableReadingBar && !viewModel.showAudioSidebar
            #endif

            if shouldShowBar {
                readingBottomBar
            }

            #if os(iOS)
            if shouldShowStatsOverlay {
                EbookOverlayIos(
                    showProgress: viewModel.settingsVM.showProgress,
                    showTimeRemainingInBook: viewModel.settingsVM.showTimeRemainingInBook,
                    showTimeRemainingInChapter: viewModel.settingsVM.showTimeRemainingInChapter,
                    showPageNumber: viewModel.settingsVM.showPageNumber,
                    overlayTransparency: viewModel.settingsVM.overlayTransparency,
                    bookFraction: viewModel.progressManager?.bookFraction,
                    bookTimeRemaining: viewModel.mediaOverlayManager?.bookTimeRemaining,
                    chapterTimeRemaining: viewModel.mediaOverlayManager?.chapterTimeRemaining,
                    currentPage: viewModel.progressManager?.chapterCurrentPage,
                    totalPages: viewModel.progressManager?.chapterTotalPages,
                    isPlaying: viewModel.mediaOverlayManager?.isPlaying ?? false,
                    hasAudioNarration: viewModel.hasAudioNarration,
                    onTogglePlaying: {
                        Task { await viewModel.progressManager?.togglePlaying() }
                    }
                )
                .transition(.opacity)
            }

            if viewModel.isReadingBarVisible {
                EbookPlayerTopToolbar(
                    hasAudioNarration: viewModel.hasAudioNarration,
                    playbackSpeed: viewModel.settingsVM.defaultPlaybackSpeed,
                    chapters: viewModel.chapterList,
                    selectedChapterId: viewModel.selectedChapterHref,
                    isSynced: viewModel.isSynced,
                    showCustomizePopover: $viewModel.showCustomizePopover,
                    showSearchSheet: $viewModel.showSearchPanel,
                    searchManager: viewModel.searchManager,
                    onDismiss: { dismiss() },
                    onPlaybackRateChange: viewModel.handlePlaybackRateChange,
                    onChapterSelected: viewModel.handleChapterSelectionByHref,
                    onSyncToggle: { enabled in
                        viewModel.isSynced = enabled
                        viewModel.mediaOverlayManager?.setSyncMode(enabled: enabled)
                    },
                    onSearchResultSelected: viewModel.handleSearchResultNavigation,
                    settingsVM: viewModel.settingsVM
                )
                .transition(.opacity)
            }
            #endif
        }
    }

    #if os(iOS)
    private var safeAreaInsets: EdgeInsets {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return EdgeInsets()
        }
        return EdgeInsets(
            top: window.safeAreaInsets.top,
            leading: window.safeAreaInsets.left,
            bottom: window.safeAreaInsets.bottom,
            trailing: window.safeAreaInsets.right
        )
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
        return AnyView(
            EbookOverlayMac(
                readingBarConfig: viewModel.settingsVM.readingBarConfig,
                progressData: progressData,
                isPlaying: mom?.isPlaying ?? false,
                playbackRate: mom?.playbackRate ?? viewModel.settingsVM.defaultPlaybackSpeed,
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
            isStatsExpanded: $viewModel.settingsVM.statsExpanded,
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
private struct TitleBarConfigurator: NSViewRepresentable {
    var isTitleBarVisible: Bool
    var windowTitle: String = "Ebook Reader"

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for nsView: NSView) {
        guard let window = nsView.window else { return }
        window.titleVisibility = .hidden
        window.title = windowTitle
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar?.isVisible = true

        updateTitleBarVisibility(for: window)
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
