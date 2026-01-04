import Foundation
import Observation

@MainActor
@Observable
public final class SettingsViewModel {
    public var fontSize: Double = kDefaultFontSize
    public var fontFamily: String = kDefaultFontFamily
    public var lineSpacing: Double = kDefaultLineSpacing
    #if os(iOS)
    public var marginLeftRight: Double = kDefaultMarginLeftRightIOS
    #else
    public var marginLeftRight: Double = kDefaultMarginLeftRightMac
    #endif
    public var marginTopBottom: Double = kDefaultMarginTopBottom
    public var wordSpacing: Double = kDefaultWordSpacing
    public var letterSpacing: Double = kDefaultLetterSpacing
    public var highlightColor: String? = nil
    public var highlightThickness: Double = kDefaultHighlightThickness
    public var readaloudHighlightUnderline: Bool = kDefaultReadaloudHighlightUnderline
    public var backgroundColor: String? = nil
    public var foregroundColor: String? = nil
    public var customCSS: String? = nil
    public var enableMarginClickNavigation: Bool = kDefaultEnableMarginClickNavigation
    public var singleColumnMode: Bool = kDefaultSingleColumnMode

    public var defaultPlaybackSpeed: Double = kDefaultPlaybackSpeed
    public var defaultVolume: Double = kDefaultVolume
    public var statsExpanded: Bool = kDefaultStatsExpanded
    public var lockViewToAudio: Bool = kDefaultLockViewToAudio

    public var enableReadingBar: Bool = kDefaultReadingBarEnabled
    #if os(iOS)
    public var showPlayerControls: Bool = kDefaultShowPlayerControlsIOS
    #else
    public var showPlayerControls: Bool = kDefaultShowPlayerControlsMac
    #endif
    public var showProgressBar: Bool = kDefaultShowProgressBar
    public var showProgress: Bool = kDefaultShowProgress
    public var showTimeRemainingInBook: Bool = kDefaultShowTimeRemainingInBook
    public var showTimeRemainingInChapter: Bool = kDefaultShowTimeRemainingInChapter
    public var showPageNumber: Bool = kDefaultShowPageNumber
    public var overlayTransparency: Double = kDefaultOverlayTransparency
    #if os(iOS)
    public var alwaysShowMiniPlayer: Bool = kDefaultAlwaysShowMiniPlayer
    #endif

    public var progressSyncIntervalSeconds: Double = kDefaultProgressSyncIntervalSeconds
    public var metadataRefreshIntervalSeconds: Double = kDefaultMetadataRefreshIntervalSeconds
    public var autoSyncToNewerServerPosition: Bool = kDefaultAutoSyncToNewerServerPosition

    public var showAudioIndicator: Bool = kDefaultShowAudioIndicator
    #if os(iOS)
    public var tabBarSlot1: String = kDefaultTabBarSlot1
    public var tabBarSlot2: String = kDefaultTabBarSlot2
    public var tapToPlayPreferredPlayer: Bool = kDefaultTapToPlayPreferredPlayer
    public var preferAudioOverEbook: Bool = kDefaultPreferAudioOverEbook
    #endif
    #if os(macOS)
    public var showTabsOnHover: Bool = kDefaultShowTabsOnHover
    #endif

    public var userHighlightColor1: String = kDefaultUserHighlightColor1
    public var userHighlightColor2: String = kDefaultUserHighlightColor2
    public var userHighlightColor3: String = kDefaultUserHighlightColor3
    public var userHighlightColor4: String = kDefaultUserHighlightColor4
    public var userHighlightColor5: String = kDefaultUserHighlightColor5
    public var userHighlightColor6: String = kDefaultUserHighlightColor6
    public var userHighlightMode: String = kDefaultUserHighlightMode
    public var readaloudHighlightMode: String = kDefaultReadaloudHighlightMode

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
        autoSyncToNewerServerPosition = config.sync.autoSyncToNewerServerPosition

        showAudioIndicator = config.library.showAudioIndicator
        #if os(iOS)
        tabBarSlot1 = config.library.tabBarSlot1
        tabBarSlot2 = config.library.tabBarSlot2
        tapToPlayPreferredPlayer = config.library.tapToPlayPreferredPlayer
        preferAudioOverEbook = config.library.preferAudioOverEbook
        #endif
        #if os(macOS)
        showTabsOnHover = config.library.showTabsOnHover
        #endif

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
            autoSyncToNewerServerPosition: autoSyncToNewerServerPosition,
            showAudioIndicator: showAudioIndicator,
            tapToPlayPreferredPlayer: tapToPlayPreferredPlayerValue,
            preferAudioOverEbook: preferAudioOverEbookValue,
            showTabsOnHover: showTabsOnHoverValue,
            userHighlightMode: userHighlightMode,
            readaloudHighlightMode: readaloudHighlightMode,
            tabBarSlot1: tabBarSlot1Value,
            tabBarSlot2: tabBarSlot2Value
        )
    }

    #if os(iOS)
    private var alwaysShowMiniPlayerValue: Bool { alwaysShowMiniPlayer }
    private var tabBarSlot1Value: String { tabBarSlot1 }
    private var tabBarSlot2Value: String { tabBarSlot2 }
    private var tapToPlayPreferredPlayerValue: Bool { tapToPlayPreferredPlayer }
    private var preferAudioOverEbookValue: Bool { preferAudioOverEbook }
    private var showTabsOnHoverValue: Bool { kDefaultShowTabsOnHover }
    #else
    private var alwaysShowMiniPlayerValue: Bool { kDefaultAlwaysShowMiniPlayer }
    private var tabBarSlot1Value: String { kDefaultTabBarSlot1 }
    private var tabBarSlot2Value: String { kDefaultTabBarSlot2 }
    private var tapToPlayPreferredPlayerValue: Bool { kDefaultTapToPlayPreferredPlayer }
    private var preferAudioOverEbookValue: Bool { kDefaultPreferAudioOverEbook }
    private var showTabsOnHoverValue: Bool { showTabsOnHover }
    #endif
}
