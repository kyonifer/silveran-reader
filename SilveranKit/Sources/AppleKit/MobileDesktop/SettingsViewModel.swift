#if os(iOS) || os(macOS)
import Foundation
import Observation
import SwiftUI

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
    public var textAlignment: String = kDefaultTextAlignment
    public var highlightColor: String? = nil
    public var highlightThickness: Double = kDefaultHighlightThickness
    public var backgroundColor: String? = nil
    public var foregroundColor: String? = nil
    public var customCSS: String? = nil
    public var enableMarginClickNavigation: Bool = kDefaultEnableMarginClickNavigation
    public var singleColumnMode: Bool = kDefaultSingleColumnMode
    public var scrollingMode: Bool = kDefaultScrollingMode

    public private(set) var playback = SilveranGlobalConfig.Playback()

    public var defaultPlaybackSpeed: Double { playback.defaultPlaybackSpeed }
    public var readaloudPlaybackSpeed: Double { playback.readaloudPlaybackSpeed }
    public var defaultVolume: Double {
        get { playback.defaultVolume }
        set { playback.defaultVolume = newValue }
    }
    public var statsExpanded: Bool {
        get { playback.statsExpanded }
        set { playback.statsExpanded = newValue }
    }
    public var lockViewToAudio: Bool {
        get { playback.lockViewToAudio }
        set { playback.lockViewToAudio = newValue }
    }

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
    public var showOverlaySkipBackward: Bool = kDefaultShowOverlaySkipBackward
    public var showOverlaySkipForward: Bool = kDefaultShowOverlaySkipForward
    public var showOverlayPlayPause: Bool = kDefaultShowOverlayPlayPause
    public var showMiniPlayerStats: Bool = kDefaultShowMiniPlayerStats
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
    public var accentColorHex: String = kDefaultAccentColorHex

    public var userHighlightColor1: String = kDefaultUserHighlightColor1
    public var userHighlightColor2: String = kDefaultUserHighlightColor2
    public var userHighlightColor3: String = kDefaultUserHighlightColor3
    public var userHighlightColor4: String = kDefaultUserHighlightColor4
    public var userHighlightColor5: String = kDefaultUserHighlightColor5
    public var userHighlightColor6: String = kDefaultUserHighlightColor6
    public var userHighlightLabel1: String = kDefaultUserHighlightLabel1
    public var userHighlightLabel2: String = kDefaultUserHighlightLabel2
    public var userHighlightLabel3: String = kDefaultUserHighlightLabel3
    public var userHighlightLabel4: String = kDefaultUserHighlightLabel4
    public var userHighlightLabel5: String = kDefaultUserHighlightLabel5
    public var userHighlightLabel6: String = kDefaultUserHighlightLabel6
    public var userHighlightMode: String = kDefaultUserHighlightMode
    public var readaloudHighlightMode: String = kDefaultReadaloudHighlightMode

    public var selectedLightThemeId: String = "builtin-light"
    public var selectedDarkThemeId: String = "builtin-dark"
    public var customThemes: [ReaderTheme] = []

    public var isLoaded: Bool = false

    @ObservationIgnored private var observerID: UUID?
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
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
            overlayTransparency: overlayTransparency,
        )
    }

    private var userHighlightColors: [String] {
        [
            userHighlightColor1, userHighlightColor2, userHighlightColor3,
            userHighlightColor4, userHighlightColor5, userHighlightColor6,
        ]
    }

    private var userHighlightLabels: [String] {
        [
            userHighlightLabel1, userHighlightLabel2, userHighlightLabel3,
            userHighlightLabel4, userHighlightLabel5, userHighlightLabel6,
        ]
    }

    public func hexColor(for color: HighlightColor) -> String {
        userHighlightColors[color.slotIndex]
    }

    public func label(for color: HighlightColor) -> String {
        userHighlightLabels[color.slotIndex]
    }

    public var highlightColorsHash: String {
        "\(userHighlightColor1)\(userHighlightColor2)\(userHighlightColor3)\(userHighlightColor4)\(userHighlightColor5)\(userHighlightColor6)"
    }

    public init() {
        initialLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSettings()
            await self.registerObserver()
        }
    }

    deinit {
        initialLoadTask?.cancel()
        if let id = observerID {
            Task {
                await SettingsActor.shared.removeObserver(id: id)
            }
        }
    }

    private func loadSettings() async {
        let config = await SettingsActor.shared.config
        playback = config.playback

        fontSize = config.reading.fontSize
        fontFamily = config.reading.fontFamily
        lineSpacing = config.reading.lineSpacing
        marginLeftRight = config.reading.marginLeftRight
        marginTopBottom = config.reading.marginTopBottom
        wordSpacing = config.reading.wordSpacing
        letterSpacing = config.reading.letterSpacing
        textAlignment = config.reading.textAlignment
        highlightColor = config.reading.highlightColor
        highlightThickness = config.reading.highlightThickness
        backgroundColor = config.reading.backgroundColor
        foregroundColor = config.reading.foregroundColor
        customCSS = config.reading.customCSS
        enableMarginClickNavigation = config.reading.enableMarginClickNavigation
        singleColumnMode = config.reading.singleColumnMode
        scrollingMode = config.reading.scrollingMode

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
        showOverlaySkipBackward = config.readingBar.showOverlaySkipBackward
        showOverlaySkipForward = config.readingBar.showOverlaySkipForward
        showOverlayPlayPause = config.readingBar.showOverlayPlayPause
        showMiniPlayerStats = config.readingBar.showMiniPlayerStats
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
        accentColorHex = config.library.accentColorHex

        userHighlightColor1 = config.reading.userHighlightColor1
        userHighlightColor2 = config.reading.userHighlightColor2
        userHighlightColor3 = config.reading.userHighlightColor3
        userHighlightColor4 = config.reading.userHighlightColor4
        userHighlightColor5 = config.reading.userHighlightColor5
        userHighlightColor6 = config.reading.userHighlightColor6
        userHighlightLabel1 = config.reading.userHighlightLabel1
        userHighlightLabel2 = config.reading.userHighlightLabel2
        userHighlightLabel3 = config.reading.userHighlightLabel3
        userHighlightLabel4 = config.reading.userHighlightLabel4
        userHighlightLabel5 = config.reading.userHighlightLabel5
        userHighlightLabel6 = config.reading.userHighlightLabel6
        userHighlightMode = config.reading.userHighlightMode
        readaloudHighlightMode = config.reading.readaloudHighlightMode

        selectedLightThemeId = ReaderTheme.migrateThemeId(config.themes.selectedLightThemeId)
        selectedDarkThemeId = ReaderTheme.migrateThemeId(config.themes.selectedDarkThemeId)
        customThemes = config.themes.customThemes

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

    public var allThemes: [ReaderTheme] {
        ReaderTheme.allBuiltIn + customThemes
    }

    public var lightThemes: [ReaderTheme] {
        ReaderTheme.themesForLightMode(customThemes: customThemes)
    }

    public var darkThemes: [ReaderTheme] {
        ReaderTheme.themesForDarkMode(customThemes: customThemes)
    }

    public func resolveTheme(id: String) -> ReaderTheme? {
        ReaderTheme.resolve(id: id, customThemes: customThemes)
    }

    public func activeThemeId(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? selectedDarkThemeId : selectedLightThemeId
    }

    public func applyActiveTheme(for colorScheme: ColorScheme) {
        let themeId = activeThemeId(for: colorScheme)
        guard let theme = resolveTheme(id: themeId) else {
            debugLog(
                "[SettingsViewModel] Could not resolve theme \(themeId), falling back to built-in"
            )
            let fallback =
                colorScheme == .dark
                ? ReaderTheme.builtInDark
                : ReaderTheme.builtInLight
            applyThemeValues(fallback)
            return
        }
        applyThemeValues(theme)
    }

    public func applyThemeValues(_ theme: ReaderTheme) {
        backgroundColor = theme.backgroundColor
        foregroundColor = theme.foregroundColor
        highlightColor = theme.highlightColor
        highlightThickness = theme.highlightThickness
        readaloudHighlightMode = theme.readaloudHighlightMode
        userHighlightColor1 = theme.userHighlightColor1
        userHighlightColor2 = theme.userHighlightColor2
        userHighlightColor3 = theme.userHighlightColor3
        userHighlightColor4 = theme.userHighlightColor4
        userHighlightColor5 = theme.userHighlightColor5
        userHighlightColor6 = theme.userHighlightColor6
        userHighlightLabel1 = theme.userHighlightLabel1
        userHighlightLabel2 = theme.userHighlightLabel2
        userHighlightLabel3 = theme.userHighlightLabel3
        userHighlightLabel4 = theme.userHighlightLabel4
        userHighlightLabel5 = theme.userHighlightLabel5
        userHighlightLabel6 = theme.userHighlightLabel6
        userHighlightMode = theme.userHighlightMode
        customCSS = theme.customCSS
        save()
    }

    public func selectTheme(id: String, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            selectedDarkThemeId = id
        } else {
            selectedLightThemeId = id
        }
        applyActiveTheme(for: colorScheme)
    }

    public func addCustomTheme(_ theme: ReaderTheme) {
        customThemes.append(theme)
        save()
    }

    public func deleteCustomTheme(id: String) {
        customThemes.removeAll { $0.id == id }
        if selectedLightThemeId == id {
            selectedLightThemeId = "builtin-light"
        }
        if selectedDarkThemeId == id {
            selectedDarkThemeId = "builtin-dark"
        }
        save()
    }

    public func duplicateTheme(_ source: ReaderTheme) -> ReaderTheme {
        let newTheme = ReaderTheme(
            name: uniqueCopyName(for: source.name, existing: allThemes.map(\.name)),
            isBuiltIn: false,
            appearance: source.appearance,
            backgroundColor: source.backgroundColor,
            foregroundColor: source.foregroundColor,
            highlightColor: source.highlightColor,
            highlightThickness: source.highlightThickness,
            readaloudHighlightMode: source.readaloudHighlightMode,
            userHighlightColor1: source.userHighlightColor1,
            userHighlightColor2: source.userHighlightColor2,
            userHighlightColor3: source.userHighlightColor3,
            userHighlightColor4: source.userHighlightColor4,
            userHighlightColor5: source.userHighlightColor5,
            userHighlightColor6: source.userHighlightColor6,
            userHighlightLabel1: source.userHighlightLabel1,
            userHighlightLabel2: source.userHighlightLabel2,
            userHighlightLabel3: source.userHighlightLabel3,
            userHighlightLabel4: source.userHighlightLabel4,
            userHighlightLabel5: source.userHighlightLabel5,
            userHighlightLabel6: source.userHighlightLabel6,
            userHighlightMode: source.userHighlightMode,
            customCSS: source.customCSS,
        )
        addCustomTheme(newTheme)
        return newTheme
    }

    public func updateCustomTheme(_ theme: ReaderTheme) {
        guard let index = customThemes.firstIndex(where: { $0.id == theme.id }) else { return }
        customThemes[index] = theme
        if !theme.availableFor(colorScheme: "light") && selectedLightThemeId == theme.id {
            selectedLightThemeId = "builtin-light"
        }
        if !theme.availableFor(colorScheme: "dark") && selectedDarkThemeId == theme.id {
            selectedDarkThemeId = "builtin-dark"
        }
        save()
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

    public func waitUntilLoaded() async {
        await initialLoadTask?.value
    }

    public func updatePlaybackSpeed(_ speed: Double, for role: PlaybackSpeedRole) {
        playback.updatePlaybackSpeed(speed, for: role)
        save()
    }

    func playbackSpeedBinding(for role: PlaybackSpeedRole) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                self?.playback.playbackSpeed(for: role) ?? kDefaultPlaybackSpeed
            },
            set: { [weak self] speed in
                self?.updatePlaybackSpeed(speed, for: role)
            },
        )
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
            textAlignment: textAlignment,
            highlightColor: .some(highlightColor),
            highlightThickness: highlightThickness,
            backgroundColor: .some(backgroundColor),
            foregroundColor: .some(foregroundColor),
            customCSS: .some(customCSS),
            enableMarginClickNavigation: enableMarginClickNavigation,
            singleColumnMode: singleColumnMode,
            scrollingMode: scrollingMode,
            playback: playback,
            enableReadingBar: enableReadingBar,
            showPlayerControls: showPlayerControls,
            showProgressBar: showProgressBar,
            showProgress: showProgress,
            showTimeRemainingInBook: showTimeRemainingInBook,
            showTimeRemainingInChapter: showTimeRemainingInChapter,
            showPageNumber: showPageNumber,
            overlayTransparency: overlayTransparency,
            alwaysShowMiniPlayer: alwaysShowMiniPlayerValue,
            showOverlaySkipBackward: showOverlaySkipBackwardValue,
            showOverlaySkipForward: showOverlaySkipForwardValue,
            showOverlayPlayPause: showOverlayPlayPauseValue,
            showMiniPlayerStats: showMiniPlayerStatsValue,
            progressSyncIntervalSeconds: progressSyncIntervalSeconds,
            metadataRefreshIntervalSeconds: metadataRefreshIntervalSeconds,
            autoSyncToNewerServerPosition: autoSyncToNewerServerPosition,
            showAudioIndicator: showAudioIndicator,
            tapToPlayPreferredPlayer: tapToPlayPreferredPlayerValue,
            preferAudioOverEbook: preferAudioOverEbookValue,
            accentColorHex: accentColorHex,
            userHighlightMode: userHighlightMode,
            readaloudHighlightMode: readaloudHighlightMode,
            tabBarSlot1: tabBarSlot1Value,
            tabBarSlot2: tabBarSlot2Value,
            selectedLightThemeId: selectedLightThemeId,
            selectedDarkThemeId: selectedDarkThemeId,
            customThemes: customThemes,
        )
    }

    #if os(iOS)
    private var alwaysShowMiniPlayerValue: Bool { alwaysShowMiniPlayer }
    private var showOverlaySkipBackwardValue: Bool { showOverlaySkipBackward }
    private var showOverlaySkipForwardValue: Bool { showOverlaySkipForward }
    private var showOverlayPlayPauseValue: Bool { showOverlayPlayPause }
    private var showMiniPlayerStatsValue: Bool { showMiniPlayerStats }
    private var tabBarSlot1Value: String { tabBarSlot1 }
    private var tabBarSlot2Value: String { tabBarSlot2 }
    private var tapToPlayPreferredPlayerValue: Bool { tapToPlayPreferredPlayer }
    private var preferAudioOverEbookValue: Bool { preferAudioOverEbook }
    #else
    private var alwaysShowMiniPlayerValue: Bool { kDefaultAlwaysShowMiniPlayer }
    private var showOverlaySkipBackwardValue: Bool { kDefaultShowOverlaySkipBackward }
    private var showOverlaySkipForwardValue: Bool { kDefaultShowOverlaySkipForward }
    private var showOverlayPlayPauseValue: Bool { kDefaultShowOverlayPlayPause }
    private var showMiniPlayerStatsValue: Bool { kDefaultShowMiniPlayerStats }
    private var tabBarSlot1Value: String { kDefaultTabBarSlot1 }
    private var tabBarSlot2Value: String { kDefaultTabBarSlot2 }
    private var tapToPlayPreferredPlayerValue: Bool { kDefaultTapToPlayPreferredPlayer }
    private var preferAudioOverEbookValue: Bool { kDefaultPreferAudioOverEbook }
    #endif

    private func uniqueCopyName(for baseName: String, existing: [String]) -> String {
        let candidate = "\(baseName) Copy"
        if !existing.contains(candidate) { return candidate }
        var n = 2
        while existing.contains("\(baseName) Copy \(n)") { n += 1 }
        return "\(baseName) Copy \(n)"
    }
}

#endif
