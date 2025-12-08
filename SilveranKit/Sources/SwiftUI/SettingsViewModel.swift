import Foundation
import Observation

@MainActor
@Observable
public final class SettingsViewModel {
    public var fontSize: Double = 24
    public var fontFamily: String = "System Default"
    public var lineSpacing: Double = 1.4
    public var marginLeftRight: Double = 8
    public var marginTopBottom: Double = 8
    public var wordSpacing: Double = 0
    public var letterSpacing: Double = 0
    public var highlightColor: String? = nil
    public var backgroundColor: String? = nil
    public var foregroundColor: String? = nil
    public var customCSS: String? = nil
    public var enableMarginClickNavigation: Bool = true
    #if os(iOS)
    public var singleColumnMode: Bool = true
    #else
    public var singleColumnMode: Bool = false
    #endif

    public var defaultPlaybackSpeed: Double = 1.0
    public var defaultVolume: Double = 1.0
    public var statsExpanded: Bool = false

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

    public var isLoaded: Bool = false

    @ObservationIgnored private var observerID: UUID?

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
        backgroundColor = config.reading.backgroundColor
        foregroundColor = config.reading.foregroundColor
        customCSS = config.reading.customCSS
        enableMarginClickNavigation = config.reading.enableMarginClickNavigation
        singleColumnMode = config.reading.singleColumnMode

        defaultPlaybackSpeed = config.playback.defaultPlaybackSpeed
        defaultVolume = config.playback.defaultVolume
        statsExpanded = config.playback.statsExpanded

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

        isLoaded = true
        debugLog("[SettingsViewModel] Settings loaded")
    }

    private func registerObserver() async {
        let id = await SettingsActor.shared.request_notify { @MainActor [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                debugLog("[SettingsViewModel] Settings changed, reloading")
                await self.loadSettings()
            }
        }
        observerID = id
        debugLog("[SettingsViewModel] Observer registered with ID \(id)")
    }

    public func save() async throws {
        try await SettingsActor.shared.updateConfig(
            fontSize: fontSize,
            fontFamily: fontFamily,
            lineSpacing: lineSpacing,
            marginLeftRight: marginLeftRight,
            marginTopBottom: marginTopBottom,
            wordSpacing: wordSpacing,
            letterSpacing: letterSpacing,
            highlightColor: highlightColor,
            backgroundColor: .some(backgroundColor),
            foregroundColor: .some(foregroundColor),
            customCSS: .some(customCSS),
            enableMarginClickNavigation: enableMarginClickNavigation,
            singleColumnMode: singleColumnMode,
            defaultPlaybackSpeed: defaultPlaybackSpeed,
            defaultVolume: defaultVolume,
            statsExpanded: statsExpanded,
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
            metadataRefreshIntervalSeconds: metadataRefreshIntervalSeconds
        )
    }

    #if os(iOS)
    private var alwaysShowMiniPlayerValue: Bool { alwaysShowMiniPlayer }
    #else
    private var alwaysShowMiniPlayerValue: Bool { false }
    #endif
}
