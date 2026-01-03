import Foundation

public let kDefaultBackgroundColorLight = "#FFFFFF"
public let kDefaultForegroundColorLight = "#000000"
public let kDefaultBackgroundColorDark = "#1A1A1A"
public let kDefaultForegroundColorDark = "#EEEEEE"

public struct SilveranGlobalConfig: Codable, Equatable, Sendable {
    public var reading: Reading
    public var playback: Playback
    public var readingBar: ReadingBar
    public var sync: Sync
    public var library: Library

    public init(
        reading: Reading = Reading(),
        playback: Playback = Playback(),
        readingBar: ReadingBar = ReadingBar(),
        sync: Sync = Sync(),
        library: Library = Library()
    ) {
        self.reading = reading
        self.playback = playback
        self.readingBar = readingBar
        self.sync = sync
        self.library = library
    }

    public struct Reading: Codable, Equatable, Sendable {
        public var fontSize: Double
        public var fontFamily: String
        public var lineSpacing: Double
        public var marginLeftRight: Double
        public var marginTopBottom: Double
        public var wordSpacing: Double
        public var letterSpacing: Double
        public var highlightColor: String?
        public var highlightThickness: Double
        public var readaloudHighlightUnderline: Bool
        public var backgroundColor: String?
        public var foregroundColor: String?
        public var customCSS: String?
        public var enableMarginClickNavigation: Bool
        public var singleColumnMode: Bool
        public var userHighlightColor1: String
        public var userHighlightColor2: String
        public var userHighlightColor3: String
        public var userHighlightColor4: String
        public var userHighlightColor5: String
        public var userHighlightColor6: String
        public var userHighlightMode: String
        public var readaloudHighlightMode: String

        public init(
            fontSize: Double = kDefaultFontSize,
            fontFamily: String = kDefaultFontFamily,
            lineSpacing: Double = kDefaultLineSpacing,
            marginLeftRight: Double? = nil,
            marginTopBottom: Double = kDefaultMarginTopBottom,
            wordSpacing: Double = kDefaultWordSpacing,
            letterSpacing: Double = kDefaultLetterSpacing,
            highlightColor: String? = nil,
            highlightThickness: Double = kDefaultHighlightThickness,
            readaloudHighlightUnderline: Bool = kDefaultReadaloudHighlightUnderline,
            backgroundColor: String? = nil,
            foregroundColor: String? = nil,
            customCSS: String? = nil,
            enableMarginClickNavigation: Bool = kDefaultEnableMarginClickNavigation,
            singleColumnMode: Bool? = nil,
            userHighlightColor1: String = kDefaultUserHighlightColor1,
            userHighlightColor2: String = kDefaultUserHighlightColor2,
            userHighlightColor3: String = kDefaultUserHighlightColor3,
            userHighlightColor4: String = kDefaultUserHighlightColor4,
            userHighlightColor5: String = kDefaultUserHighlightColor5,
            userHighlightColor6: String = kDefaultUserHighlightColor6,
            userHighlightMode: String = kDefaultUserHighlightMode,
            readaloudHighlightMode: String = kDefaultReadaloudHighlightMode
        ) {
            self.fontSize = fontSize
            self.fontFamily = fontFamily
            self.lineSpacing = lineSpacing
            #if os(iOS)
            self.marginLeftRight = marginLeftRight ?? kDefaultMarginLeftRightIOS
            #else
            self.marginLeftRight = marginLeftRight ?? kDefaultMarginLeftRightMac
            #endif
            self.marginTopBottom = marginTopBottom
            self.wordSpacing = wordSpacing
            self.letterSpacing = letterSpacing
            self.highlightColor = highlightColor
            self.highlightThickness = highlightThickness
            self.readaloudHighlightUnderline = readaloudHighlightUnderline
            self.backgroundColor = backgroundColor
            self.foregroundColor = foregroundColor
            self.singleColumnMode = singleColumnMode ?? kDefaultSingleColumnMode
            self.customCSS = customCSS
            self.enableMarginClickNavigation = enableMarginClickNavigation
            self.userHighlightColor1 = userHighlightColor1
            self.userHighlightColor2 = userHighlightColor2
            self.userHighlightColor3 = userHighlightColor3
            self.userHighlightColor4 = userHighlightColor4
            self.userHighlightColor5 = userHighlightColor5
            self.userHighlightColor6 = userHighlightColor6
            self.userHighlightMode = userHighlightMode
            self.readaloudHighlightMode = readaloudHighlightMode
        }

        public init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            fontSize = (try? container?.decode(Double.self, forKey: .fontSize)) ?? kDefaultFontSize
            fontFamily = (try? container?.decode(String.self, forKey: .fontFamily)) ?? kDefaultFontFamily
            lineSpacing = (try? container?.decode(Double.self, forKey: .lineSpacing)) ?? kDefaultLineSpacing
            #if os(iOS)
            marginLeftRight = (try? container?.decode(Double.self, forKey: .marginLeftRight)) ?? kDefaultMarginLeftRightIOS
            #else
            marginLeftRight = (try? container?.decode(Double.self, forKey: .marginLeftRight)) ?? kDefaultMarginLeftRightMac
            #endif
            marginTopBottom = (try? container?.decode(Double.self, forKey: .marginTopBottom)) ?? kDefaultMarginTopBottom
            wordSpacing = (try? container?.decode(Double.self, forKey: .wordSpacing)) ?? kDefaultWordSpacing
            letterSpacing = (try? container?.decode(Double.self, forKey: .letterSpacing)) ?? kDefaultLetterSpacing
            highlightColor = try? container?.decode(String.self, forKey: .highlightColor)
            highlightThickness = (try? container?.decode(Double.self, forKey: .highlightThickness)) ?? kDefaultHighlightThickness
            readaloudHighlightUnderline = (try? container?.decode(Bool.self, forKey: .readaloudHighlightUnderline)) ?? kDefaultReadaloudHighlightUnderline
            backgroundColor = try? container?.decode(String.self, forKey: .backgroundColor)
            foregroundColor = try? container?.decode(String.self, forKey: .foregroundColor)
            customCSS = try? container?.decode(String.self, forKey: .customCSS)
            enableMarginClickNavigation = (try? container?.decode(Bool.self, forKey: .enableMarginClickNavigation)) ?? kDefaultEnableMarginClickNavigation
            singleColumnMode = (try? container?.decode(Bool.self, forKey: .singleColumnMode)) ?? kDefaultSingleColumnMode
            userHighlightColor1 = (try? container?.decode(String.self, forKey: .userHighlightColor1)) ?? kDefaultUserHighlightColor1
            userHighlightColor2 = (try? container?.decode(String.self, forKey: .userHighlightColor2)) ?? kDefaultUserHighlightColor2
            userHighlightColor3 = (try? container?.decode(String.self, forKey: .userHighlightColor3)) ?? kDefaultUserHighlightColor3
            userHighlightColor4 = (try? container?.decode(String.self, forKey: .userHighlightColor4)) ?? kDefaultUserHighlightColor4
            userHighlightColor5 = (try? container?.decode(String.self, forKey: .userHighlightColor5)) ?? kDefaultUserHighlightColor5
            userHighlightColor6 = (try? container?.decode(String.self, forKey: .userHighlightColor6)) ?? kDefaultUserHighlightColor6
            userHighlightMode = (try? container?.decode(String.self, forKey: .userHighlightMode)) ?? kDefaultUserHighlightMode
            readaloudHighlightMode = (try? container?.decode(String.self, forKey: .readaloudHighlightMode)) ?? kDefaultReadaloudHighlightMode
        }

        private enum CodingKeys: String, CodingKey {
            case fontSize, fontFamily, lineSpacing, marginLeftRight, marginTopBottom
            case wordSpacing, letterSpacing, highlightColor, highlightThickness
            case readaloudHighlightUnderline, backgroundColor, foregroundColor
            case customCSS, enableMarginClickNavigation, singleColumnMode
            case userHighlightColor1, userHighlightColor2, userHighlightColor3
            case userHighlightColor4, userHighlightColor5, userHighlightColor6
            case userHighlightMode, readaloudHighlightMode
        }
    }

    public struct Playback: Codable, Equatable, Sendable {
        public var defaultPlaybackSpeed: Double
        public var defaultVolume: Double
        public var statsExpanded: Bool
        public var lockViewToAudio: Bool

        public init(
            defaultPlaybackSpeed: Double = kDefaultPlaybackSpeed,
            defaultVolume: Double = kDefaultVolume,
            statsExpanded: Bool = kDefaultStatsExpanded,
            lockViewToAudio: Bool = kDefaultLockViewToAudio
        ) {
            self.defaultPlaybackSpeed = defaultPlaybackSpeed
            self.defaultVolume = defaultVolume
            self.statsExpanded = statsExpanded
            self.lockViewToAudio = lockViewToAudio
        }
    }

    public struct ReadingBar: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var showPlayerControls: Bool
        public var showProgressBar: Bool
        public var showProgress: Bool
        public var showTimeRemainingInBook: Bool
        public var showTimeRemainingInChapter: Bool
        public var showPageNumber: Bool
        public var overlayTransparency: Double
        public var alwaysShowMiniPlayer: Bool

        public init(
            enabled: Bool = kDefaultReadingBarEnabled,
            showPlayerControls: Bool? = nil,
            showProgressBar: Bool = kDefaultShowProgressBar,
            showProgress: Bool = kDefaultShowProgress,
            showTimeRemainingInBook: Bool = kDefaultShowTimeRemainingInBook,
            showTimeRemainingInChapter: Bool = kDefaultShowTimeRemainingInChapter,
            showPageNumber: Bool = kDefaultShowPageNumber,
            overlayTransparency: Double = kDefaultOverlayTransparency,
            alwaysShowMiniPlayer: Bool = kDefaultAlwaysShowMiniPlayer
        ) {
            self.enabled = enabled
            #if os(iOS)
            self.showPlayerControls = showPlayerControls ?? kDefaultShowPlayerControlsIOS
            #else
            self.showPlayerControls = showPlayerControls ?? kDefaultShowPlayerControlsMac
            #endif
            self.showProgressBar = showProgressBar
            self.showProgress = showProgress
            self.showTimeRemainingInBook = showTimeRemainingInBook
            self.showTimeRemainingInChapter = showTimeRemainingInChapter
            self.showPageNumber = showPageNumber
            self.overlayTransparency = overlayTransparency
            self.alwaysShowMiniPlayer = alwaysShowMiniPlayer
        }
    }

    public struct Sync: Codable, Equatable, Sendable {
        public var progressSyncIntervalSeconds: Double
        public var metadataRefreshIntervalSeconds: Double
        public var isManuallyOffline: Bool
        public var autoSyncToNewerServerPosition: Bool

        public init(
            progressSyncIntervalSeconds: Double = kDefaultProgressSyncIntervalSeconds,
            metadataRefreshIntervalSeconds: Double = kDefaultMetadataRefreshIntervalSeconds,
            isManuallyOffline: Bool = kDefaultIsManuallyOffline,
            autoSyncToNewerServerPosition: Bool = kDefaultAutoSyncToNewerServerPosition
        ) {
            self.progressSyncIntervalSeconds = progressSyncIntervalSeconds
            self.metadataRefreshIntervalSeconds = metadataRefreshIntervalSeconds
            self.isManuallyOffline = isManuallyOffline
            self.autoSyncToNewerServerPosition = autoSyncToNewerServerPosition
        }

        public var isProgressSyncDisabled: Bool {
            progressSyncIntervalSeconds < 0
        }

        public var isMetadataRefreshDisabled: Bool {
            metadataRefreshIntervalSeconds < 0
        }
    }

    public struct Library: Codable, Equatable, Sendable {
        public var showAudioIndicator: Bool
        public var tabBarSlot1: String
        public var tabBarSlot2: String

        public init(
            showAudioIndicator: Bool = kDefaultShowAudioIndicator,
            tabBarSlot1: String = kDefaultTabBarSlot1,
            tabBarSlot2: String = kDefaultTabBarSlot2
        ) {
            self.showAudioIndicator = showAudioIndicator
            self.tabBarSlot1 = tabBarSlot1
            self.tabBarSlot2 = tabBarSlot2
        }

        public init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            showAudioIndicator = (try? container?.decode(Bool.self, forKey: .showAudioIndicator)) ?? kDefaultShowAudioIndicator
            tabBarSlot1 = (try? container?.decode(String.self, forKey: .tabBarSlot1)) ?? kDefaultTabBarSlot1
            tabBarSlot2 = (try? container?.decode(String.self, forKey: .tabBarSlot2)) ?? kDefaultTabBarSlot2
        }

        private enum CodingKeys: String, CodingKey {
            case showAudioIndicator, tabBarSlot1, tabBarSlot2
        }
    }
}

@globalActor
public actor SettingsActor {
    public static let shared = SettingsActor()

    private(set) public var config: SilveranGlobalConfig
    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]

    private let fileManager: FileManager
    private let storageURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedURL = Self.defaultStorageURL(fileManager: fileManager)
        storageURL = resolvedURL

        do {
            try Self.ensureStorageDirectory(for: resolvedURL, using: fileManager)
            config = try Self.loadConfig(from: resolvedURL, fileManager: fileManager)
            #if os(iOS)
            config.readingBar.showPlayerControls = true
            #endif
        } catch {
            config = SilveranGlobalConfig()
            try? Self.save(config: config, to: resolvedURL, fileManager: fileManager)
        }
    }

    @discardableResult
    public func request_notify(callback: @Sendable @MainActor @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func updateConfig(
        fontSize: Double? = nil,
        fontFamily: String? = nil,
        lineSpacing: Double? = nil,
        marginLeftRight: Double? = nil,
        marginTopBottom: Double? = nil,
        wordSpacing: Double? = nil,
        letterSpacing: Double? = nil,
        highlightColor: String?? = nil,
        highlightThickness: Double? = nil,
        readaloudHighlightUnderline: Bool? = nil,
        backgroundColor: String?? = nil,
        foregroundColor: String?? = nil,
        customCSS: String?? = nil,
        enableMarginClickNavigation: Bool? = nil,
        singleColumnMode: Bool? = nil,
        defaultPlaybackSpeed: Double? = nil,
        defaultVolume: Double? = nil,
        statsExpanded: Bool? = nil,
        lockViewToAudio: Bool? = nil,
        enableReadingBar: Bool? = nil,
        showPlayerControls: Bool? = nil,
        showProgressBar: Bool? = nil,
        showProgress: Bool? = nil,
        showTimeRemainingInBook: Bool? = nil,
        showTimeRemainingInChapter: Bool? = nil,
        showPageNumber: Bool? = nil,
        overlayTransparency: Double? = nil,
        alwaysShowMiniPlayer: Bool? = nil,
        progressSyncIntervalSeconds: Double? = nil,
        metadataRefreshIntervalSeconds: Double? = nil,
        isManuallyOffline: Bool? = nil,
        autoSyncToNewerServerPosition: Bool? = nil,
        showAudioIndicator: Bool? = nil,
        userHighlightColor1: String? = nil,
        userHighlightColor2: String? = nil,
        userHighlightColor3: String? = nil,
        userHighlightColor4: String? = nil,
        userHighlightColor5: String? = nil,
        userHighlightColor6: String? = nil,
        userHighlightMode: String? = nil,
        readaloudHighlightMode: String? = nil,
        tabBarSlot1: String? = nil,
        tabBarSlot2: String? = nil
    ) throws {
        var updated = config

        if let fontSize { updated.reading.fontSize = fontSize }
        if let fontFamily { updated.reading.fontFamily = fontFamily }
        if let lineSpacing { updated.reading.lineSpacing = lineSpacing }
        if let marginLeftRight { updated.reading.marginLeftRight = marginLeftRight }
        if let marginTopBottom { updated.reading.marginTopBottom = marginTopBottom }
        if let wordSpacing { updated.reading.wordSpacing = wordSpacing }
        if let letterSpacing { updated.reading.letterSpacing = letterSpacing }
        if let highlightColor { updated.reading.highlightColor = highlightColor }
        if let highlightThickness { updated.reading.highlightThickness = highlightThickness }
        if let readaloudHighlightUnderline {
            updated.reading.readaloudHighlightUnderline = readaloudHighlightUnderline
        }
        if let backgroundColor { updated.reading.backgroundColor = backgroundColor }
        if let foregroundColor { updated.reading.foregroundColor = foregroundColor }
        if let customCSS { updated.reading.customCSS = customCSS }
        if let enableMarginClickNavigation {
            updated.reading.enableMarginClickNavigation = enableMarginClickNavigation
        }
        if let singleColumnMode { updated.reading.singleColumnMode = singleColumnMode }
        if let defaultPlaybackSpeed { updated.playback.defaultPlaybackSpeed = defaultPlaybackSpeed }
        if let defaultVolume { updated.playback.defaultVolume = defaultVolume }
        if let statsExpanded { updated.playback.statsExpanded = statsExpanded }
        if let lockViewToAudio { updated.playback.lockViewToAudio = lockViewToAudio }
        if let enableReadingBar { updated.readingBar.enabled = enableReadingBar }
        if let showPlayerControls { updated.readingBar.showPlayerControls = showPlayerControls }
        if let showProgressBar { updated.readingBar.showProgressBar = showProgressBar }
        if let showProgress { updated.readingBar.showProgress = showProgress }
        if let showTimeRemainingInBook {
            updated.readingBar.showTimeRemainingInBook = showTimeRemainingInBook
        }
        if let showTimeRemainingInChapter {
            updated.readingBar.showTimeRemainingInChapter = showTimeRemainingInChapter
        }
        if let showPageNumber { updated.readingBar.showPageNumber = showPageNumber }
        if let overlayTransparency { updated.readingBar.overlayTransparency = overlayTransparency }
        if let alwaysShowMiniPlayer {
            updated.readingBar.alwaysShowMiniPlayer = alwaysShowMiniPlayer
        }
        if let progressSyncIntervalSeconds {
            debugLog(
                "[SettingsActor] Updating progressSyncIntervalSeconds to \(progressSyncIntervalSeconds)s"
            )
            updated.sync.progressSyncIntervalSeconds = progressSyncIntervalSeconds
        }
        if let metadataRefreshIntervalSeconds {
            debugLog(
                "[SettingsActor] Updating metadataRefreshIntervalSeconds to \(metadataRefreshIntervalSeconds)s"
            )
            updated.sync.metadataRefreshIntervalSeconds = metadataRefreshIntervalSeconds
        }
        if let isManuallyOffline {
            updated.sync.isManuallyOffline = isManuallyOffline
        }
        if let autoSyncToNewerServerPosition {
            updated.sync.autoSyncToNewerServerPosition = autoSyncToNewerServerPosition
        }
        if let showAudioIndicator {
            updated.library.showAudioIndicator = showAudioIndicator
        }
        if let tabBarSlot1 {
            updated.library.tabBarSlot1 = tabBarSlot1
        }
        if let tabBarSlot2 {
            updated.library.tabBarSlot2 = tabBarSlot2
        }
        if let userHighlightColor1 {
            updated.reading.userHighlightColor1 = userHighlightColor1
        }
        if let userHighlightColor2 {
            updated.reading.userHighlightColor2 = userHighlightColor2
        }
        if let userHighlightColor3 {
            updated.reading.userHighlightColor3 = userHighlightColor3
        }
        if let userHighlightColor4 {
            updated.reading.userHighlightColor4 = userHighlightColor4
        }
        if let userHighlightColor5 {
            updated.reading.userHighlightColor5 = userHighlightColor5
        }
        if let userHighlightColor6 {
            updated.reading.userHighlightColor6 = userHighlightColor6
        }
        if let userHighlightMode {
            updated.reading.userHighlightMode = userHighlightMode
        }
        if let readaloudHighlightMode {
            updated.reading.readaloudHighlightMode = readaloudHighlightMode
        }

        #if os(iOS)
        updated.readingBar.showPlayerControls = true
        #endif

        config = updated
        try persistCurrentConfig()
        debugLog(
            "[SettingsActor] Config updated and persisted - Progress: \(config.sync.progressSyncIntervalSeconds)s, Metadata: \(config.sync.metadataRefreshIntervalSeconds)s"
        )

        let observersList = Array(observers.values)
        Task { @MainActor in
            for observer in observersList {
                observer()
            }
        }
    }
}

extension SettingsActor {
    fileprivate static func defaultStorageURL(fileManager: FileManager) -> URL {
        let appSupport: URL
        if let resolved = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = resolved
        } else {
            let fallback =
                fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            appSupport = fallback
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "SilveranReader"
        let base: URL =
            if appSupport.path.contains("/Containers/") {
                appSupport
            } else {
                appSupport.appendingPathComponent(bundleID, isDirectory: true)
            }

        let configDirectory = base.appendingPathComponent("Config", isDirectory: true)
        return configDirectory.appendingPathComponent(
            "SilveranGlobalConfig.json",
            isDirectory: false
        )
    }

    fileprivate static func ensureStorageDirectory(for fileURL: URL, using fileManager: FileManager)
        throws
    {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    fileprivate static func loadConfig(from url: URL, fileManager: FileManager) throws
        -> SilveranGlobalConfig
    {
        guard fileManager.fileExists(atPath: url.path) else {
            return SilveranGlobalConfig()
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SilveranGlobalConfig.self, from: data)
    }

    fileprivate static func save(
        config: SilveranGlobalConfig,
        to url: URL,
        fileManager _: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: [.atomic])
    }

    fileprivate func persistCurrentConfig() throws {
        try Self.ensureStorageDirectory(for: storageURL, using: fileManager)
        try Self.save(config: config, to: storageURL, fileManager: fileManager)
    }
}
