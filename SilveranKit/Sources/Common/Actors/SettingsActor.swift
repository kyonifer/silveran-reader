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

    public init(
        reading: Reading = Reading(),
        playback: Playback = Playback(),
        readingBar: ReadingBar = ReadingBar(),
        sync: Sync = Sync()
    ) {
        self.reading = reading
        self.playback = playback
        self.readingBar = readingBar
        self.sync = sync
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
        public var backgroundColor: String?
        public var foregroundColor: String?
        public var customCSS: String?
        public var enableMarginClickNavigation: Bool
        public var singleColumnMode: Bool

        public init(
            fontSize: Double = 24,
            fontFamily: String = "System Default",
            lineSpacing: Double = 1.4,
            marginLeftRight: Double = 8,
            marginTopBottom: Double = 8,
            wordSpacing: Double = 0,
            letterSpacing: Double = 0,
            highlightColor: String? = nil,
            backgroundColor: String? = nil,
            foregroundColor: String? = nil,
            customCSS: String? = nil,
            enableMarginClickNavigation: Bool = true,
            singleColumnMode: Bool? = nil
        ) {
            self.fontSize = fontSize
            self.fontFamily = fontFamily
            self.lineSpacing = lineSpacing
            self.marginLeftRight = marginLeftRight
            self.marginTopBottom = marginTopBottom
            self.wordSpacing = wordSpacing
            self.letterSpacing = letterSpacing
            self.highlightColor = highlightColor
            self.backgroundColor = backgroundColor
            self.foregroundColor = foregroundColor
            #if os(iOS)
            self.singleColumnMode = singleColumnMode ?? true
            #else
            self.singleColumnMode = singleColumnMode ?? false
            #endif
            self.customCSS = customCSS
            self.enableMarginClickNavigation = enableMarginClickNavigation
        }
    }

    public struct Playback: Codable, Equatable, Sendable {
        public var defaultPlaybackSpeed: Double
        public var defaultVolume: Double
        public var statsExpanded: Bool
        public var lockViewToAudio: Bool

        public init(
            defaultPlaybackSpeed: Double = 1.0,
            defaultVolume: Double = 1.0,
            statsExpanded: Bool = false,
            lockViewToAudio: Bool = true
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
            enabled: Bool = true,
            showPlayerControls: Bool? = nil,
            showProgressBar: Bool = false,
            showProgress: Bool = true,
            showTimeRemainingInBook: Bool = true,
            showTimeRemainingInChapter: Bool = true,
            showPageNumber: Bool = true,
            overlayTransparency: Double = 0.8,
            alwaysShowMiniPlayer: Bool = false
        ) {
            self.enabled = enabled
            #if os(iOS)
            self.showPlayerControls = showPlayerControls ?? true
            #else
            self.showPlayerControls = showPlayerControls ?? false
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

        public init(
            progressSyncIntervalSeconds: Double = 30,
            metadataRefreshIntervalSeconds: Double = 300,
            isManuallyOffline: Bool = false
        ) {
            self.progressSyncIntervalSeconds = progressSyncIntervalSeconds
            self.metadataRefreshIntervalSeconds = metadataRefreshIntervalSeconds
            self.isManuallyOffline = isManuallyOffline
        }

        public var isProgressSyncDisabled: Bool {
            progressSyncIntervalSeconds < 0
        }

        public var isMetadataRefreshDisabled: Bool {
            metadataRefreshIntervalSeconds < 0
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
        isManuallyOffline: Bool? = nil
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
        if let alwaysShowMiniPlayer { updated.readingBar.alwaysShowMiniPlayer = alwaysShowMiniPlayer }
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
                await observer()
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
