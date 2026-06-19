import AVFoundation
import Foundation

#if os(iOS)
import MediaPlayer
#endif

public enum AudiobookError: Error, LocalizedError {
    case invalidFileFormat(String)
    case fileNotFound
    case failedToLoadMetadata
    case playbackFailed(String)

    public var errorDescription: String? {
        switch self {
            case .invalidFileFormat(let format):
                return
                    "Audiobook format '\(format)' is not supported. Audiobooks must use manifest.json packages."
            case .fileNotFound:
                return "Audiobook file not found at the specified path."
            case .failedToLoadMetadata:
                return "Failed to load audiobook metadata or chapters."
            case .playbackFailed(let reason):
                return "Playback failed: \(reason)"
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct AudiobookChapter: Sendable, Hashable {
    public let id: String
    public let title: String
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let href: String

    public init(
        id: String? = nil,
        title: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        href: String,
    ) {
        self.id = id ?? href
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.href = href
    }
}

public struct AudiobookTrack: Sendable, Hashable {
    public let href: String
    public let url: URL
    public let type: String?
    public let duration: TimeInterval
    public let startTime: TimeInterval

    public init(
        href: String,
        url: URL,
        type: String?,
        duration: TimeInterval,
        startTime: TimeInterval,
    ) {
        self.href = href
        self.url = url
        self.type = type
        self.duration = duration
        self.startTime = startTime
    }
}

public struct AudiobookMetadata: Sendable {
    public let chapters: [AudiobookChapter]
    public let tracks: [AudiobookTrack]
    public let totalDuration: TimeInterval
    public let title: String?
    public let author: String?

    public init(
        chapters: [AudiobookChapter],
        tracks: [AudiobookTrack] = [],
        totalDuration: TimeInterval,
        title: String?,
        author: String?,
    ) {
        self.chapters = chapters
        self.tracks = tracks
        self.totalDuration = totalDuration
        self.title = title
        self.author = author
    }
}

public struct AudiobookPlaybackState: Sendable {
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let currentChapterIndex: Int?
    public let playbackRate: Float
    public let volume: Float
    public let currentTrackHref: String?
    public let currentTrackType: String?
    public let currentTrackTime: TimeInterval

    public init(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        currentChapterIndex: Int?,
        playbackRate: Float,
        volume: Float,
        currentTrackHref: String? = nil,
        currentTrackType: String? = nil,
        currentTrackTime: TimeInterval = 0,
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.currentChapterIndex = currentChapterIndex
        self.playbackRate = playbackRate
        self.volume = volume
        self.currentTrackHref = currentTrackHref
        self.currentTrackType = currentTrackType
        self.currentTrackTime = currentTrackTime
    }
}

@globalActor
public actor AudiobookActor {
    public static let shared = AudiobookActor()

    private var player: AVAudioPlayer?
    private var metadata: AudiobookMetadata?
    private var currentPackageRootURL: URL?
    private var currentTrackIndex: Int = 0
    private var desiredPlaybackRate: Float = 1.0
    private var desiredVolume: Float = 1.0
    private var playbackMonitorTask: Task<Void, Never>?
    private var stateObservers: [UUID: @Sendable @MainActor (AudiobookPlaybackState) -> Void] = [:]

    #if os(iOS)
    private var artworkImage: UIImage?
    private var nowPlayingUpdateTimer: Timer?
    private var audioSessionObserversConfigured = false
    #endif

    private init() {}

    public func validateAndLoadAudiobook(url: URL) async throws -> AudiobookMetadata {
        let source = try await loadManifestPackage(from: url)
        metadata = source
        currentPackageRootURL = try packageRootURL(for: url)
        currentTrackIndex = 0
        player = nil
        return source
    }

    private struct Manifest: Decodable {
        struct Metadata: Decodable {
            let title: String?
            let author: String?
            let narrator: String?
            let duration: Double?

            enum CodingKeys: String, CodingKey {
                case title
                case author
                case narrator
                case duration
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                title = Self.decodeStringOrStringArray(container, forKey: .title)
                author = Self.decodeStringOrStringArray(container, forKey: .author)
                narrator = Self.decodeStringOrStringArray(container, forKey: .narrator)
                duration = try? container.decode(Double.self, forKey: .duration)
            }

            private static func decodeStringOrStringArray(
                _ container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys,
            ) -> String? {
                if let string = try? container.decode(String.self, forKey: key) {
                    return string
                }
                if let strings = try? container.decode([String].self, forKey: key) {
                    let joined =
                        strings
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    return joined.isEmpty ? nil : joined
                }
                return nil
            }
        }

        struct Link: Decodable {
            let href: String
            let type: String?
            let title: String?
            let duration: Double?
        }

        let metadata: Metadata?
        let readingOrder: [Link]
        let toc: [Link]?
    }

    private func packageRootURL(for url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudiobookError.fileNotFound
        }

        if url.hasDirectoryPath {
            return url
        }

        if url.lastPathComponent == "manifest.json" {
            return url.deletingLastPathComponent()
        }

        throw AudiobookError.invalidFileFormat(url.pathExtension)
    }

    private func loadManifestPackage(from url: URL) async throws -> AudiobookMetadata {
        let rootURL = try packageRootURL(for: url)
        let manifestURL = rootURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AudiobookError.fileNotFound
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.readingOrder.isEmpty else {
            throw AudiobookError.failedToLoadMetadata
        }

        var tracks: [AudiobookTrack] = []
        var cursor: TimeInterval = 0

        for item in manifest.readingOrder {
            let resourceURL = try resolveManifestHref(item.href, rootURL: rootURL)
            guard FileManager.default.fileExists(atPath: resourceURL.path) else {
                throw AudiobookError.fileNotFound
            }

            let duration: TimeInterval
            if let manifestDuration = item.duration {
                duration = manifestDuration
            } else {
                duration = (try? await loadDuration(from: resourceURL)) ?? 0
            }
            tracks.append(
                AudiobookTrack(
                    href: stripFragment(from: item.href),
                    url: resourceURL,
                    type: item.type,
                    duration: duration,
                    startTime: cursor,
                )
            )
            cursor += duration
        }

        let totalDuration = manifest.metadata?.duration ?? cursor
        let chapters = await loadManifestChapters(
            from: manifest,
            tracks: tracks,
            totalDuration: totalDuration,
        )

        return AudiobookMetadata(
            chapters: chapters,
            tracks: tracks,
            totalDuration: totalDuration,
            title: manifest.metadata?.title,
            author: manifest.metadata?.author ?? manifest.metadata?.narrator,
        )
    }

    private func loadDuration(from url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw AudiobookError.failedToLoadMetadata
        }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func loadManifestChapters(
        from manifest: Manifest,
        tracks: [AudiobookTrack],
        totalDuration: TimeInterval,
    ) async -> [AudiobookChapter] {
        var chapters: [AudiobookChapter] = []
        let tocItems = manifest.toc ?? []

        for (index, item) in tocItems.enumerated() {
            guard let start = globalTime(for: item.href, tracks: tracks) else { continue }
            let title = item.title ?? "Chapter \(index + 1)"
            chapters.append(
                AudiobookChapter(
                    id: "toc-\(index)-\(item.href)",
                    title: title,
                    startTime: start,
                    duration: 0,
                    href: item.href,
                )
            )
        }

        chapters.sort { $0.startTime < $1.startTime }

        if chapters.isEmpty {
            for (index, track) in tracks.enumerated() {
                chapters.append(
                    AudiobookChapter(
                        id: "track-\(index)-\(track.href)",
                        title: fallbackChapterTitle(for: track.href, index: index),
                        startTime: track.startTime,
                        duration: track.duration,
                        href: "\(track.href)#t=0",
                    )
                )
            }
        } else {
            chapters = chapters.enumerated().map { index, chapter in
                let nextStart =
                    index + 1 < chapters.count
                    ? chapters[index + 1].startTime
                    : totalDuration
                return AudiobookChapter(
                    id: chapter.id,
                    title: chapter.title,
                    startTime: chapter.startTime,
                    duration: max(0, nextStart - chapter.startTime),
                    href: chapter.href,
                )
            }
        }

        if chapters.isEmpty {
            chapters.append(
                AudiobookChapter(
                    id: "chapter-0",
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: tracks.first.map { "\($0.href)#t=0" } ?? "chapter-0",
                )
            )
        }

        return normalizedChapterTitles(chapters, tracks: tracks)
    }

    private func normalizedChapterTitles(
        _ chapters: [AudiobookChapter],
        tracks: [AudiobookTrack],
    ) -> [AudiobookChapter] {
        let uniqueTitles = Set(
            chapters
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard chapters.count > 1, uniqueTitles.count <= 1 else { return chapters }

        return chapters.enumerated().map { index, chapter in
            let title =
                track(for: chapter, tracks: tracks)
                .map { fallbackChapterTitle(for: $0.href, index: index) }
                ?? "Chapter \(index + 1)"

            return AudiobookChapter(
                id: chapter.id,
                title: title,
                startTime: chapter.startTime,
                duration: chapter.duration,
                href: chapter.href,
            )
        }
    }

    private func track(for chapter: AudiobookChapter, tracks: [AudiobookTrack]) -> AudiobookTrack? {
        tracks.last { $0.startTime <= chapter.startTime + 0.25 }
    }

    private func fallbackChapterTitle(for href: String, index: Int) -> String {
        let path = stripFragment(from: href).removingPercentEncoding ?? stripFragment(from: href)
        let title = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter \(index + 1)" : title
    }

    private func resolveManifestHref(_ href: String, rootURL: URL) throws -> URL {
        let path = stripFragment(from: href)
        if let url = URL(string: path), url.isFileURL {
            return url
        }
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty else {
            throw AudiobookError.failedToLoadMetadata
        }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded)
        }
        return rootURL.appendingPathComponent(decoded, isDirectory: false)
    }

    private func stripFragment(from href: String) -> String {
        href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
    }

    private func fragmentTime(from href: String) -> TimeInterval {
        guard let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first else {
            return 0
        }
        let fragmentString = String(fragment)
        guard fragmentString.hasPrefix("t=") else { return 0 }
        return TimeInterval(fragmentString.dropFirst(2)) ?? 0
    }

    private func globalTime(for href: String, tracks: [AudiobookTrack]) -> TimeInterval? {
        let trackHref = stripFragment(from: href)
        guard let track = tracks.first(where: { $0.href == trackHref }) else {
            return nil
        }
        return track.startTime + fragmentTime(from: href)
    }

    nonisolated private func loadChapters(from asset: AVAsset, totalDuration: TimeInterval)
        async throws -> [AudiobookChapter]
    {
        guard let urlAsset = asset as? AVURLAsset else {
            return [
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0",
                )
            ]
        }

        let languages: [Locale]
        do {
            languages = try await asset.load(.availableChapterLocales)
        } catch {
            return [
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0",
                )
            ]
        }

        guard !languages.isEmpty else {
            return [
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0",
                )
            ]
        }

        let chapterMetadataGroups = try await urlAsset.loadChapterMetadataGroups(
            withTitleLocale: languages[0],
            containingItemsWithCommonKeys: [.commonKeyTitle],
        )

        var chapters: [AudiobookChapter] = []

        for (index, group) in chapterMetadataGroups.enumerated() {
            let startTime = CMTimeGetSeconds(group.timeRange.start)
            let duration = CMTimeGetSeconds(group.timeRange.duration)

            var chapterTitle = "Chapter \(index + 1)"

            for item in group.items {
                if let key = item.commonKey, key == .commonKeyTitle {
                    if let value = try? await item.load(.value) {
                        if let stringValue = value as? String {
                            chapterTitle = stringValue
                        } else if let dataValue = value as? Data,
                            let stringValue = String(data: dataValue, encoding: .utf8)
                        {
                            chapterTitle = stringValue
                        }
                    }
                }
            }

            chapters.append(
                AudiobookChapter(
                    title: chapterTitle,
                    startTime: startTime,
                    duration: duration,
                    href: "chapter-\(index)",
                )
            )
        }

        if chapters.isEmpty {
            chapters.append(
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0",
                )
            )
        }

        return chapters
    }

    public func preparePlayer() async throws {
        guard let metadata, metadata.tracks.indices.contains(currentTrackIndex) else {
            throw AudiobookError.failedToLoadMetadata
        }

        do {
            #if os(iOS)
            setupAudioSession()
            configureAudioSessionObservers()
            #endif

            let track = metadata.tracks[currentTrackIndex]
            let player = try AVAudioPlayer(contentsOf: track.url)
            player.prepareToPlay()
            player.enableRate = true
            player.rate = desiredPlaybackRate
            player.volume = desiredVolume
            self.player = player

            #if os(iOS)
            await configureRemoteCommands()
            updateNowPlayingInfo()
            startNowPlayingUpdateTimer()
            #endif
        } catch {
            throw AudiobookError.playbackFailed(error.localizedDescription)
        }
    }

    #if os(iOS)
    public func setCoverImage(_ image: UIImage) {
        artworkImage = image
    }
    #endif

    public func play() async throws {
        if player == nil {
            try await preparePlayer()
            guard player != nil else {
                throw AudiobookError.playbackFailed("Player not initialized")
            }
        }

        #if os(iOS)
        ensureAudioSessionActive()
        #endif
        player?.play()
        startPlaybackMonitor()
        await notifyStateChange()
    }

    public func pause() async {
        debugLog("[AudiobookActor] pause() called")
        player?.pause()
        stopPlaybackMonitor()
        await notifyStateChange()
    }

    public func togglePlayPause() async throws {
        if player?.isPlaying == true {
            await pause()
        } else {
            try await play()
        }
    }

    public func seek(to time: TimeInterval) async {
        guard let metadata, !metadata.tracks.isEmpty else { return }
        let clampedTime = min(max(time, 0), metadata.totalDuration)
        let trackIndex = trackIndex(for: clampedTime, in: metadata.tracks)
        let wasPlaying = player?.isPlaying == true
        currentTrackIndex = trackIndex
        do {
            try await preparePlayer()
            if let track = metadata.tracks[safe: trackIndex] {
                player?.currentTime = max(0, clampedTime - track.startTime)
            }
            if wasPlaying {
                player?.play()
                startPlaybackMonitor()
            }
        } catch {
            debugLog("[AudiobookActor] seek failed: \(error)")
        }
        await notifyStateChange()
    }

    public func seekToFraction(_ fraction: Double) async {
        guard let duration = metadata?.totalDuration else { return }
        let targetTime = duration * fraction
        await seek(to: targetTime)
    }

    public func skipForward(_ seconds: TimeInterval = 15) async {
        let state = await getCurrentState()
        let newTime = min((state?.currentTime ?? 0) + seconds, metadata?.totalDuration ?? 0)
        await seek(to: newTime)
    }

    public func skipBackward(_ seconds: TimeInterval = 15) async {
        let state = await getCurrentState()
        let newTime = max((state?.currentTime ?? 0) - seconds, 0)
        await seek(to: newTime)
    }

    public func setPlaybackRate(_ rate: Double) async {
        desiredPlaybackRate = Float(rate)
        player?.rate = Float(rate)
        await notifyStateChange()
    }

    public func setVolume(_ volume: Double) async {
        desiredVolume = Float(volume)
        player?.volume = Float(volume)
        await notifyStateChange()
    }

    public func seekToChapter(href: String) async {
        guard let chapters = metadata?.chapters else { return }
        guard
            let chapter = chapters.first(where: { $0.id == href })
                ?? chapters.first(where: { $0.href == href })
        else { return }
        await seek(to: chapter.startTime)
    }

    public func getCurrentChapterIndex() async -> Int? {
        guard let chapters = metadata?.chapters else { return nil }
        let currentTime = await currentGlobalTime()

        for (index, chapter) in chapters.enumerated() {
            let chapterEnd = chapter.startTime + chapter.duration
            if currentTime >= chapter.startTime && currentTime < chapterEnd {
                return index
            }
        }

        return chapters.isEmpty ? nil : chapters.count - 1
    }

    public func getCurrentState() async -> AudiobookPlaybackState? {
        guard let metadata else { return nil }

        return AudiobookPlaybackState(
            isPlaying: player?.isPlaying == true,
            currentTime: await currentGlobalTime(),
            duration: metadata.totalDuration,
            currentChapterIndex: await getCurrentChapterIndex(),
            playbackRate: player?.rate ?? desiredPlaybackRate,
            volume: player?.volume ?? desiredVolume,
            currentTrackHref: metadata.tracks[safe: currentTrackIndex]?.href,
            currentTrackType: metadata.tracks[safe: currentTrackIndex]?.type,
            currentTrackTime: player?.currentTime ?? 0,
        )
    }

    public func addStateObserver(
        id: UUID = UUID(),
        observer: @escaping @Sendable @MainActor (AudiobookPlaybackState) -> Void,
    ) async -> UUID {
        debugLog("[AudiobookActor] addStateObserver called, id=\(id)")
        stateObservers[id] = observer
        debugLog("[AudiobookActor] Observer stored, count=\(stateObservers.count)")
        if let state = await getCurrentState() {
            await observer(state)
        }
        return id
    }

    public func removeStateObserver(id: UUID) async {
        stateObservers.removeValue(forKey: id)
    }

    private func notifyStateChange() async {
        guard let state = await getCurrentState() else {
            debugLog("[AudiobookActor] notifyStateChange: no current state")
            return
        }

        debugLog(
            "[AudiobookActor] notifyStateChange: isPlaying=\(state.isPlaying), observers=\(stateObservers.count)"
        )

        #if os(iOS)
        updateNowPlayingInfo()
        #endif

        for observer in stateObservers.values {
            await observer(state)
        }
    }

    private func currentGlobalTime() async -> TimeInterval {
        currentGlobalTimeSync()
    }

    private func currentGlobalTimeSync() -> TimeInterval {
        guard let metadata else { return 0 }
        let trackStart = metadata.tracks[safe: currentTrackIndex]?.startTime ?? 0
        return trackStart + (player?.currentTime ?? 0)
    }

    private func trackIndex(for globalTime: TimeInterval, in tracks: [AudiobookTrack]) -> Int {
        guard !tracks.isEmpty else { return 0 }
        for (index, track) in tracks.enumerated() {
            let end = track.startTime + track.duration
            if globalTime >= track.startTime && globalTime < end {
                return index
            }
        }
        return tracks.count - 1
    }

    private func startPlaybackMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = Task { [weak self = self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { break }
                await self.advanceTrackIfNeeded()
            }
        }
    }

    private func stopPlaybackMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
    }

    private func advanceTrackIfNeeded() async {
        guard let player, player.isPlaying, let metadata else { return }
        guard player.currentTime >= max(0, player.duration - 0.25) else { return }

        let nextIndex = currentTrackIndex + 1
        guard metadata.tracks.indices.contains(nextIndex) else {
            stopPlaybackMonitor()
            await notifyStateChange()
            return
        }

        currentTrackIndex = nextIndex
        do {
            try await preparePlayer()
            self.player?.play()
            await notifyStateChange()
        } catch {
            debugLog("[AudiobookActor] Failed to advance track: \(error)")
            stopPlaybackMonitor()
        }
    }

    public func getTotalProgressFraction() async -> Double {
        guard let duration = metadata?.totalDuration, duration > 0 else { return 0.0 }
        return await currentGlobalTime() / duration
    }

    public func seekToTotalProgressFraction(_ fraction: Double) async {
        guard let duration = metadata?.totalDuration else { return }
        let targetTime = duration * fraction
        await seek(to: targetTime)
    }

    #if os(iOS)
    @MainActor
    private func configureRemoteCommands() {
        debugLog("[AudiobookActor] Configuring remote commands")
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @AudiobookActor in
                do {
                    debugLog("[AudiobookActor] Remote play command received")
                    try await AudiobookActor.shared.play()
                } catch {
                    debugLog("[AudiobookActor] Remote play failed: \(error)")
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @AudiobookActor in
                debugLog("[AudiobookActor] Remote pause command received")
                await AudiobookActor.shared.pause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { _ in
            Task { @AudiobookActor in
                debugLog("[AudiobookActor] Remote skip forward command received")
                await AudiobookActor.shared.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @AudiobookActor in
                debugLog("[AudiobookActor] Remote skip backward command received")
                await AudiobookActor.shared.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionInChapter = positionEvent.positionTime
            Task { @AudiobookActor in
                debugLog("[AudiobookActor] Remote seek command received: \(positionInChapter)")
                await AudiobookActor.shared.seekWithinCurrentChapter(to: positionInChapter)
            }
            return .success
        }

        debugLog(
            "[AudiobookActor] Remote commands enabled: play=\(commandCenter.playCommand.isEnabled), pause=\(commandCenter.pauseCommand.isEnabled), skipF=\(commandCenter.skipForwardCommand.isEnabled), skipB=\(commandCenter.skipBackwardCommand.isEnabled), changePos=\(commandCenter.changePlaybackPositionCommand.isEnabled)"
        )
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.setActiveAudioPlayer(.audiobook)
        }
        debugLog("[AudiobookActor] Remote commands configured")
    }

    // MARK: - Audio Session Management

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[AudiobookActor] Audio session configured for playback")
        } catch {
            debugLog("[AudiobookActor] Failed to configure audio session: \(error)")
        }
    }

    private func ensureAudioSessionActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            debugLog("[AudiobookActor] Audio session re-activated before play")
        } catch {
            debugLog("[AudiobookActor] Failed to re-activate audio session: \(error)")
        }
    }

    private func configureAudioSessionObservers() {
        guard !audioSessionObserversConfigured else { return }

        let session = AVAudioSession.sharedInstance()

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil,
        ) { [weak self] notification in
            self?.handleAudioSessionInterruption(notification)
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil,
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }

        audioSessionObserversConfigured = true
        debugLog("[AudiobookActor] Audio session observers registered")
    }

    nonisolated private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        let shouldResume: Bool
        if type == .ended,
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
        {
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            shouldResume = options.contains(.shouldResume)
        } else {
            shouldResume = false
        }

        Task { @AudiobookActor in
            switch type {
                case .began:
                    debugLog("[AudiobookActor] Audio session interrupted - pausing")
                    await AudiobookActor.shared.pause()
                case .ended:
                    if shouldResume {
                        debugLog("[AudiobookActor] Audio session interruption ended - resuming")
                        do {
                            try await AudiobookActor.shared.play()
                        } catch {
                            debugLog(
                                "[AudiobookActor] Failed to resume after interruption: \(error)"
                            )
                        }
                    } else {
                        debugLog("[AudiobookActor] Audio session interruption ended - no resume")
                    }
                @unknown default:
                    break
            }
        }
    }

    nonisolated private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return
        }

        Task { @AudiobookActor in
            switch reason {
                case .oldDeviceUnavailable:
                    debugLog("[AudiobookActor] Audio route lost (device unavailable) - pausing")
                    await AudiobookActor.shared.pause()

                case .newDeviceAvailable:
                    debugLog("[AudiobookActor] New audio device available")

                case .routeConfigurationChange:
                    debugLog("[AudiobookActor] Audio route configuration changed")

                default:
                    debugLog("[AudiobookActor] Audio route change reason: \(reason.rawValue)")
            }
        }
    }

    private func removeAudioSessionObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil,
        )
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.routeChangeNotification,
            object: nil,
        )
        audioSessionObserversConfigured = false
        debugLog("[AudiobookActor] Audio session observers removed")
    }

    private func updateNowPlayingInfo() {
        guard let player = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata?.title ?? "Audiobook"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata?.author ?? ""

        if let chapters = metadata?.chapters,
            let currentIndex = getCurrentChapterIndexSync(),
            currentIndex < chapters.count
        {
            let chapter = chapters[currentIndex]
            let timeInChapter = currentGlobalTimeSync() - chapter.startTime

            nowPlayingInfo[MPMediaItemPropertyArtist] = chapter.title
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = chapter.duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, timeInChapter)
        } else {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] =
                metadata?.totalDuration ?? player.duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentGlobalTimeSync()
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] =
            player.isPlaying ? Double(player.rate) : 0.0

        if let artwork = artworkImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in
                artwork
            }
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nowPlayingInfo
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    private func getCurrentChapterIndexSync() -> Int? {
        guard player != nil, let chapters = metadata?.chapters else { return nil }
        let currentTime = currentGlobalTimeSync()

        for (index, chapter) in chapters.enumerated() {
            let chapterEnd = chapter.startTime + chapter.duration
            if currentTime >= chapter.startTime && currentTime < chapterEnd {
                return index
            }
        }

        return chapters.isEmpty ? nil : chapters.count - 1
    }

    private func clearRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        debugLog(
            "[AudiobookActor] Clearing remote commands (before): play=\(commandCenter.playCommand.isEnabled), pause=\(commandCenter.pauseCommand.isEnabled), skipF=\(commandCenter.skipForwardCommand.isEnabled), skipB=\(commandCenter.skipBackwardCommand.isEnabled), changePos=\(commandCenter.changePlaybackPositionCommand.isEnabled)"
        )
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        debugLog("[AudiobookActor] Remote commands cleared")
    }

    public func seekWithinCurrentChapter(to timeInChapter: TimeInterval) async {
        guard let chapters = metadata?.chapters,
            let currentIndex = await getCurrentChapterIndex(),
            currentIndex < chapters.count
        else {
            debugLog("[AudiobookActor] seekWithinCurrentChapter - no valid chapter")
            return
        }

        let chapter = chapters[currentIndex]
        // Clamp to stay strictly within chapter bounds
        let minTime = 0.1
        let maxTime = max(0.1, chapter.duration - 0.5)
        let clampedTime = max(minTime, min(timeInChapter, maxTime))
        let absoluteTime = chapter.startTime + clampedTime

        debugLog(
            "[AudiobookActor] seekWithinCurrentChapter: \(timeInChapter)s in chapter \(currentIndex) (\(chapter.title)) -> \(absoluteTime)s absolute"
        )
        await seek(to: absoluteTime)
    }

    public func skipToNextChapter() async {
        guard let chapters = metadata?.chapters,
            let currentIndex = await getCurrentChapterIndex(),
            currentIndex < chapters.count - 1
        else { return }
        await seekToChapter(href: chapters[currentIndex + 1].id)
    }

    public func skipToPreviousChapter() async {
        guard let chapters = metadata?.chapters,
            let currentIndex = await getCurrentChapterIndex(),
            currentIndex > 0
        else { return }
        await seekToChapter(href: chapters[currentIndex - 1].id)
    }

    private func startNowPlayingUpdateTimer() {
        stopNowPlayingUpdateTimer()

        // Update Now Playing every second to keep the lock screen UI in sync,
        // especially for chapter transitions during playback
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.refreshNowPlayingInfo()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingUpdateTimer = timer
    }

    private func refreshNowPlayingInfo() {
        guard player?.isPlaying == true else { return }
        updateNowPlayingInfo()
    }

    private func stopNowPlayingUpdateTimer() {
        nowPlayingUpdateTimer?.invalidate()
        nowPlayingUpdateTimer = nil
    }
    #endif

    public func cleanup() async {
        debugLog("[AudiobookActor] Cleanup called")
        stopPlaybackMonitor()
        player?.stop()
        player = nil
        metadata = nil
        currentPackageRootURL = nil
        currentTrackIndex = 0
        stateObservers.removeAll()

        #if os(iOS)
        stopNowPlayingUpdateTimer()
        clearRemoteCommands()
        if await SMILPlayerActor.shared.activeAudioPlayer == .audiobook {
            await SMILPlayerActor.shared.setActiveAudioPlayer(.none)
        }
        removeAudioSessionObservers()
        artworkImage = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation,
            )
        } catch {
            debugLog("[AudiobookActor] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}
