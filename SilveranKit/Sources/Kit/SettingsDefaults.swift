import Foundation

// MARK: - Reading Settings

public let kDefaultFontSize: Double = 24
public let kDefaultFontFamily = "System Default"
public let kDefaultLineSpacing: Double = 1.4
public let kDefaultMarginLeftRightIOS: Double = 2
public let kDefaultMarginLeftRightMac: Double = 5
public let kDefaultMarginTopBottom: Double = 8
public let kDefaultWordSpacing: Double = 0
public let kDefaultLetterSpacing: Double = 0
public let kDefaultJustifyText = true
public let kDefaultTextAlignment = "justify"
public let kTextAlignmentValues = ["left", "justify", "right"]
public let kDefaultHighlightThickness: Double = 1.0
public let kDefaultEnableMarginClickNavigation = true
public let kDefaultSingleColumnMode = true
public let kDefaultScrollingMode = false

// MARK: - Highlight Colors

// Slot order is defined by HighlightColor's case order: Pink, Orange, Yellow,
// Green, Blue, Purple. These palettes are indexed by that position and must
// stay aligned with it.
public let kDefaultUserHighlightColorsLight = [
    "#B849B8", "#E67400", "#FFB600", "#00915A", "#005493", "#6C3CC1",
]
public let kDefaultUserHighlightColorsDark = [
    "#C4527A", "#C47A3A", "#B8A030", "#3A9E7E", "#4A7ACC", "#8A52CC",
]
public let kDefaultUserHighlightLabels = [
    "Pink", "Orange", "Yellow", "Green", "Blue", "Purple",
]

public let kDefaultUserHighlightColor1 = kDefaultUserHighlightColorsLight[0]
public let kDefaultUserHighlightColor2 = kDefaultUserHighlightColorsLight[1]
public let kDefaultUserHighlightColor3 = kDefaultUserHighlightColorsLight[2]
public let kDefaultUserHighlightColor4 = kDefaultUserHighlightColorsLight[3]
public let kDefaultUserHighlightColor5 = kDefaultUserHighlightColorsLight[4]
public let kDefaultUserHighlightColor6 = kDefaultUserHighlightColorsLight[5]
public let kDefaultUserHighlightLabel1 = kDefaultUserHighlightLabels[0]
public let kDefaultUserHighlightLabel2 = kDefaultUserHighlightLabels[1]
public let kDefaultUserHighlightLabel3 = kDefaultUserHighlightLabels[2]
public let kDefaultUserHighlightLabel4 = kDefaultUserHighlightLabels[3]
public let kDefaultUserHighlightLabel5 = kDefaultUserHighlightLabels[4]
public let kDefaultUserHighlightLabel6 = kDefaultUserHighlightLabels[5]
public let kDefaultUserHighlightMode = "underline"
public let kDefaultReadaloudHighlightMode = "background"

// MARK: - Playback Settings

public let kDefaultPlaybackSpeed: Double = 1.0
public let kMinimumPlaybackSpeed: Double = 0.75
public let kMaximumPlaybackSpeed: Double = 4.0
public let kDefaultVolume: Double = 1.0
public let kDefaultStatsExpanded = false
public let kDefaultLockViewToAudio = true

public enum PlaybackSpeedRole: Equatable, Sendable {
    case listening
    case readaloud
}

public enum PlaybackSpeedPolicy {
    public static let sliderStep = 0.05
    public static let presetStep = 0.25

    public static let presetRates = stride(
        from: kMinimumPlaybackSpeed,
        through: kMaximumPlaybackSpeed,
        by: presetStep,
    ).map { $0 }

    public static let quickPresetRates = [
        0.75, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 4.0,
    ]
}

// MARK: - Reading Bar Settings

public let kDefaultReadingBarEnabled = true
public let kDefaultShowPlayerControlsIOS = true
public let kDefaultShowPlayerControlsMac = false
public let kDefaultShowProgressBar = false
public let kDefaultShowProgress = true
public let kDefaultShowTimeRemainingInBook = true
public let kDefaultShowTimeRemainingInChapter = true
public let kDefaultShowPageNumber = true
public let kDefaultOverlayTransparency: Double = 0.8
public let kDefaultAlwaysShowMiniPlayer = false
public let kDefaultShowOverlaySkipBackward = true
public let kDefaultShowOverlaySkipForward = true
public let kDefaultShowOverlayPlayPause = true
public let kDefaultShowMiniPlayerStats = false

// MARK: - Sync Settings

public let kDefaultProgressSyncIntervalSeconds: Double = 30
public let kDefaultMetadataRefreshIntervalSeconds: Double = 300
public let kDefaultIsManuallyOffline = false
public let kDefaultAutoSyncToNewerServerPosition = false

// MARK: - Library Settings

public let kDefaultShowAudioIndicator = true
public let kDefaultTabBarSlot1 = "books"
public let kDefaultTabBarSlot2 = "series"
public let kDefaultTapToPlayPreferredPlayer = false
public let kDefaultPreferAudioOverEbook = false
public let kDefaultAccentColorHex = "#EB722F"

// MARK: - tvOS Settings

public let kDefaultTVSubtitleFontSize: Double = 48
public let kDefaultTVFontFamily = "serif"
public let kDefaultTVBackgroundStyle = "cover"
public let kDefaultTVActiveSentenceStyle = "whiteText"
public let kDefaultTVHighlightColor = "yellow"
public let kDefaultTVInactiveTextIntensity = "dim"
public let kDefaultTVTextWidth = "medium"
public let kDefaultTVLineSpacing = "medium"
public let kDefaultTVTextAlignment = "leading"
public let kDefaultTVScrollMode = "paragraph"
