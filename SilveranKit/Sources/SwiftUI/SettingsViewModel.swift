import Foundation
import Observation

@MainActor
@Observable
public final class SettingsViewModel {
    public var fontSize: Double = 24
    public var fontFamily: String = "System Default"
    public var lineSpacing: Double = 1.4
    #if os(iOS)
    public var marginLeftRight: Double = 2
    #else
    public var marginLeftRight: Double = 5
    #endif
    public var marginTopBottom: Double = 8
    public var wordSpacing: Double = 0
    public var letterSpacing: Double = 0
    public var highlightColor: String? = nil
    public var highlightThickness: Double = 1.0
    public var readaloudHighlightUnderline: Bool = false
    public var backgroundColor: String? = nil
    public var foregroundColor: String? = nil
    public var customCSS: String? = nil
    public var enableMarginClickNavigation: Bool = true
    public var singleColumnMode: Bool = true

    public var defaultPlaybackSpeed: Double = 1.0
    public var defaultVolume: Double = 1.0
    public var statsExpanded: Bool = false
    public var lockViewToAudio: Bool = true

    public var enableReadingBar: Bool = true
    #if os(iOS)
    public var showPlayerControls: Bool = true
    #else
    public var showPlayerControls: Bool = false
    #endif
    public var showProgressBar: Bool = false
    public var showProgress: Bool = true
    public var showTimeRemainingInBook: Bool = true
    public var showTimeRemainingInChapter: Bool = true
    public var showPageNumber: Bool = true
    public var overlayTransparency: Double = 0.8
    #if os(iOS)
    public var alwaysShowMiniPlayer: Bool = false
    #endif

    public var progressSyncIntervalSeconds: Double = 30
    public var metadataRefreshIntervalSeconds: Double = 300

    public var showAudioIndicator: Bool = false

    public var userHighlightColor1: String = "#B5B83E"
    public var userHighlightColor2: String = "#4E90C7"
    public var userHighlightColor3: String = "#198744"
    public var userHighlightColor4: String = "#E25EA3"
    public var userHighlightColor5: String = "#CE8C4A"
    public var userHighlightColor6: String = "#B366FF"
    public var userHighlightMode: String = "background"
    public var readaloudHighlightMode: String = "background"

    public var isLoaded: Bool = false

    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public var readingBarConfig: SilveranGlobalConfig.ReadingBar {
        SilveranGlobalConfig.ReadingBar(
            enabled: enableReadingBar,
            showPlayerControls: showPlayerControls,
            showProgressBar: showProgressBar,
            showProgress: showProgress,
            showTimeRemainingInBook: showTimeRemainingInBook,
            showTimeRemainingInChapter: showTimeRemainingInChapter,
            showPageNumber: showPageNumber,
            overlayTransparency: overlayTransparency
        )
    }

    public func hexColor(for color: HighlightColor) -> String {
        switch color {
            case .yellow: return userHighlightColor1
            case .blue: return userHighlightColor2
            case .green: return userHighlightColor3
            case .pink: return userHighlightColor4
            case .orange: return userHighlightColor5
            case .purple: return userHighlightColor6
        }
    }

    public var highlightColorsHash: String {
        "\(userHighlightColor1)\(userHighlightColor2)\(userHighlightColor3)\(userHighlightColor4)\(userHighlightColor5)\(userHighlightColor6)"
    }

    public init() {
        Task {
            await loadSettings()
            await registerObserver()
        }
    }

    deinit {
        if let id = observerID {
            Task {
                await SettingsActor.shared.removeObserver(id: id)
            }
        }
    }

    private func loadSettings() async {
        let config = await SettingsActor.shared.config

        fontSize = config.reading.fontSize
        fontFamily = config.reading.fontFamily
        lineSpacing = config.reading.lineSpacing
        marginLeftRight = config.reading.marginLeftRight
        marginTopBottom = config.reading.marginTopBottom
        wordSpacing = config.reading.wordSpacing
        letterSpacing = config.reading.letterSpacing
        highlightColor = config.reading.highlightColor
        highlightThickness = config.reading.highlightThickness
        readaloudHighlightUnderline = config.reading.readaloudHighlightUnderline
        backgroundColor = config.reading.backgroundColor
        foregroundColor = config.reading.foregroundColor
        customCSS = config.reading.customCSS
        enableMarginClickNavigation = config.reading.enableMarginClickNavigation
        singleColumnMode = config.reading.singleColumnMode

        defaultPlaybackSpeed = config.playback.defaultPlaybackSpeed
        defaultVolume = config.playback.defaultVolume
        statsExpanded = config.playback.statsExpanded
        lockViewToAudio = config.playback.lockViewToAudio

        enableReadingBar = config.readingBar.enabled
        showPlayerControls = config.readingBar.showPlayerControls
        showProgressBar = config.readingBar.showProgressBar
        showProgress = config.readingBar.showProgress
        showTimeRemainingInBook = config.readingBar.showTimeRemainingInBook
        showTimeRemainingInChapter = config.readingBar.showTimeRemainingInChapter
        showPageNumber = config.readingBar.showPageNumber
        overlayTransparency = config.readingBar.overlayTransparency
        #if os(iOS)
        alwaysShowMiniPlayer = config.readingBar.alwaysShowMiniPlayer
        #endif

        progressSyncIntervalSeconds = config.sync.progressSyncIntervalSeconds
        metadataRefreshIntervalSeconds = config.sync.metadataRefreshIntervalSeconds

        showAudioIndicator = config.library.showAudioIndicator

        userHighlightColor1 = config.reading.userHighlightColor1
        userHighlightColor2 = config.reading.userHighlightColor2
        userHighlightColor3 = config.reading.userHighlightColor3
        userHighlightColor4 = config.reading.userHighlightColor4
        userHighlightColor5 = config.reading.userHighlightColor5
        userHighlightColor6 = config.reading.userHighlightColor6
        userHighlightMode = config.reading.userHighlightMode
        readaloudHighlightMode = config.reading.readaloudHighlightMode

        isLoaded = true
    }

    private func registerObserver() async {
        let id = await SettingsActor.shared.request_notify { @MainActor [weak self] in
            guard let self else { return }
            guard self.saveTask == nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadSettings()
            }
        }
        observerID = id
    }

    public func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? await persistNow()
            saveTask = nil
        }
    }

    private func persistNow() async throws {
        try await SettingsActor.shared.updateConfig(
            fontSize: fontSize,
            fontFamily: fontFamily,
            lineSpacing: lineSpacing,
            marginLeftRight: marginLeftRight,
            marginTopBottom: marginTopBottom,
            wordSpacing: wordSpacing,
            letterSpacing: letterSpacing,
            highlightColor: .some(highlightColor),
            highlightThickness: highlightThickness,
            readaloudHighlightUnderline: readaloudHighlightUnderline,
            backgroundColor: .some(backgroundColor),
            foregroundColor: .some(foregroundColor),
            customCSS: .some(customCSS),
            enableMarginClickNavigation: enableMarginClickNavigation,
            singleColumnMode: singleColumnMode,
            defaultPlaybackSpeed: defaultPlaybackSpeed,
            defaultVolume: defaultVolume,
            statsExpanded: statsExpanded,
            lockViewToAudio: lockViewToAudio,
            enableReadingBar: enableReadingBar,
            showPlayerControls: showPlayerControls,
            showProgressBar: showProgressBar,
            showProgress: showProgress,
            showTimeRemainingInBook: showTimeRemainingInBook,
            showTimeRemainingInChapter: showTimeRemainingInChapter,
            showPageNumber: showPageNumber,
            overlayTransparency: overlayTransparency,
            alwaysShowMiniPlayer: alwaysShowMiniPlayerValue,
            progressSyncIntervalSeconds: progressSyncIntervalSeconds,
            metadataRefreshIntervalSeconds: metadataRefreshIntervalSeconds,
            showAudioIndicator: showAudioIndicator,
            userHighlightMode: userHighlightMode,
            readaloudHighlightMode: readaloudHighlightMode
        )
    }

    #if os(iOS)
    private var alwaysShowMiniPlayerValue: Bool { alwaysShowMiniPlayer }
    #else
    private var alwaysShowMiniPlayerValue: Bool { false }
    #endif
}
