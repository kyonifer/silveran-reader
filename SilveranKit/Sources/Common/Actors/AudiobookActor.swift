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
                    "Audiobook format '\(format)' is not supported. Only M4B audiobooks are currently supported."
            case .fileNotFound:
                return "Audiobook file not found at the specified path."
            case .failedToLoadMetadata:
                return "Failed to load audiobook metadata or chapters."
            case .playbackFailed(let reason):
                return "Playback failed: \(reason)"
        }
    }
}

public struct AudiobookChapter: Sendable, Hashable {
    public let title: String
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let href: String

    public init(title: String, startTime: TimeInterval, duration: TimeInterval, href: String) {
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.href = href
    }
}

public struct AudiobookMetadata: Sendable {
    public let chapters: [AudiobookChapter]
    public let totalDuration: TimeInterval
    public let title: String?
    public let author: String?

    public init(
        chapters: [AudiobookChapter],
        totalDuration: TimeInterval,
        title: String?,
        author: String?
    ) {
        self.chapters = chapters
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

    public init(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        currentChapterIndex: Int?,
        playbackRate: Float,
        volume: Float
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.currentChapterIndex = currentChapterIndex
        self.playbackRate = playbackRate
        self.volume = volume
    }
}

@globalActor
public actor AudiobookActor {
    public static let shared = AudiobookActor()

    private var player: AVAudioPlayer?
    private var metadata: AudiobookMetadata?
    private var currentFileURL: URL?
    private var stateObservers: [UUID: @Sendable @MainActor (AudiobookPlaybackState) -> Void] = [:]

    #if os(iOS)
    private var artworkImage: UIImage?
    private var remoteCommandsConfigured = false
    private var nowPlayingUpdateTimer: Timer?
    #endif

    private init() {}

    public func validateAndLoadAudiobook(url: URL) async throws -> AudiobookMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudiobookError.fileNotFound
        }

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "m4b" else {
            throw AudiobookError.invalidFileFormat(fileExtension)
        }

        let asset = AVURLAsset(url: url)

        guard try await asset.load(.isPlayable) else {
            throw AudiobookError.failedToLoadMetadata
        }

        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)

        let commonMetadata = try await asset.load(.commonMetadata)
        var title: String?
        var author: String?

        for item in commonMetadata {
            if let key = item.commonKey {
                if key == .commonKeyTitle {
                    title = try await item.load(.value) as? String
                } else if key == .commonKeyArtist {
                    author = try await item.load(.value) as? String
                }
            }
        }

        let chapters = try await loadChapters(from: asset, totalDuration: totalDuration)

        #if os(iOS)
        for item in commonMetadata {
            if let key = item.commonKey, key == .commonKeyArtwork {
                if let data = try? await item.load(.value) as? Data {
                    artworkImage = UIImage(data: data)
                }
            }
        }
        #endif

        let metadata = AudiobookMetadata(
            chapters: chapters,
            totalDuration: totalDuration,
            title: title,
            author: author
        )

        self.metadata = metadata
        self.currentFileURL = url

        return metadata
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
                    href: "chapter-0"
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
                    href: "chapter-0"
                )
            ]
        }

        guard !languages.isEmpty else {
            return [
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0"
                )
            ]
        }

        let chapterMetadataGroups = try await urlAsset.loadChapterMetadataGroups(
            withTitleLocale: languages[0],
            containingItemsWithCommonKeys: [.commonKeyTitle]
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
                    href: "chapter-\(index)"
                )
            )
        }

        if chapters.isEmpty {
            chapters.append(
                AudiobookChapter(
                    title: "Full Book",
                    startTime: 0,
                    duration: totalDuration,
                    href: "chapter-0"
                )
            )
        }

        return chapters
    }

    public func preparePlayer() async throws {
        guard let url = currentFileURL else {
            throw AudiobookError.fileNotFound
        }

        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            #endif

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.enableRate = true
            self.player = player

            #if os(iOS)
            configureRemoteCommands()
            updateNowPlayingInfo()
            startNowPlayingUpdateTimer()
            #endif
        } catch {
            throw AudiobookError.playbackFailed(error.localizedDescription)
        }
    }

    public func play() async throws {
        if player == nil {
            try await preparePlayer()
            guard player != nil else {
                throw AudiobookError.playbackFailed("Player not initialized")
            }
        }

        player?.play()
        await notifyStateChange()
    }

    public func pause() async {
        player?.pause()
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
        player?.currentTime = time
        await notifyStateChange()
    }

    public func seekToFraction(_ fraction: Double) async {
        guard let duration = player?.duration else { return }
        let targetTime = duration * fraction
        await seek(to: targetTime)
    }

    public func skipForward(_ seconds: TimeInterval = 15) async {
        guard let player = player else { return }
        let newTime = min(player.currentTime + seconds, player.duration)
        await seek(to: newTime)
    }

    public func skipBackward(_ seconds: TimeInterval = 15) async {
        guard let player = player else { return }
        let newTime = max(player.currentTime - seconds, 0)
        await seek(to: newTime)
    }

    public func setPlaybackRate(_ rate: Double) async {
        guard let player = player else { return }
        player.rate = Float(rate)
        await notifyStateChange()
    }

    public func setVolume(_ volume: Double) async {
        guard let player = player else { return }
        player.volume = Float(volume)
        await notifyStateChange()
    }

    public func seekToChapter(href: String) async {
        guard let chapters = metadata?.chapters else { return }
        guard let chapter = chapters.first(where: { $0.href == href }) else { return }
        await seek(to: chapter.startTime)
    }

    public func getCurrentChapterIndex() async -> Int? {
        guard let player = player, let chapters = metadata?.chapters else { return nil }
        let currentTime = player.currentTime

        for (index, chapter) in chapters.enumerated() {
            let chapterEnd = chapter.startTime + chapter.duration
            if currentTime >= chapter.startTime && currentTime < chapterEnd {
                return index
            }
        }

        return chapters.isEmpty ? nil : chapters.count - 1
    }

    public func getCurrentState() async -> AudiobookPlaybackState? {
        guard let player = player else { return nil }

        return AudiobookPlaybackState(
            isPlaying: player.isPlaying,
            currentTime: player.currentTime,
            duration: player.duration,
            currentChapterIndex: await getCurrentChapterIndex(),
            playbackRate: player.rate,
            volume: player.volume
        )
    }

    public func addStateObserver(
        id: UUID = UUID(),
        observer: @escaping @Sendable @MainActor (AudiobookPlaybackState) -> Void
    ) async -> UUID {
        stateObservers[id] = observer
        if let state = await getCurrentState() {
            await observer(state)
        }
        return id
    }

    public func removeStateObserver(id: UUID) async {
        stateObservers.removeValue(forKey: id)
    }

    private func notifyStateChange() async {
        guard let state = await getCurrentState() else { return }

        #if os(iOS)
        updateNowPlayingInfo()
        #endif

        for observer in stateObservers.values {
            await observer(state)
        }
    }

    public func getTotalProgressFraction() async -> Double {
        guard let player = player else { return 0.0 }
        guard player.duration > 0 else { return 0.0 }
        return player.currentTime / player.duration
    }

    public func seekToTotalProgressFraction(_ fraction: Double) async {
        guard let player = player else { return }
        let targetTime = player.duration * fraction
        await seek(to: targetTime)
    }

    #if os(iOS)
    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @AudiobookActor in
                do {
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
                await AudiobookActor.shared.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @AudiobookActor in
                do {
                    try await AudiobookActor.shared.togglePlayPause()
                } catch {
                    debugLog("[AudiobookActor] Remote toggle play/pause failed: \(error)")
                }
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.skipBackward()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.skipToNextChapter()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.skipToPreviousChapter()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @AudiobookActor in
                await AudiobookActor.shared.seek(to: position)
            }
            return .success
        }

        remoteCommandsConfigured = true
        debugLog("[AudiobookActor] Remote commands configured")
    }

    private func updateNowPlayingInfo() {
        guard let player = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate != 0 ? player.rate : 1.0),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        if let title = metadata?.title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let author = metadata?.author {
            nowPlayingInfo[MPMediaItemPropertyArtist] = author
        }

        if let chapters = metadata?.chapters,
            let currentIndex = getCurrentChapterIndexSync(),
            currentIndex < chapters.count
        {
            let chapter = chapters[currentIndex]
            nowPlayingInfo[MPMediaItemPropertyTitle] =
                "\(metadata?.title ?? "Audiobook") - \(chapter.title)"
        }

        if let artwork = artworkImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in
                artwork
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func getCurrentChapterIndexSync() -> Int? {
        guard let player = player, let chapters = metadata?.chapters else { return nil }
        let currentTime = player.currentTime

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

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        remoteCommandsConfigured = false
        debugLog("[AudiobookActor] Remote commands cleared")
    }

    public func skipToNextChapter() async {
        guard let chapters = metadata?.chapters,
            let currentIndex = await getCurrentChapterIndex(),
            currentIndex < chapters.count - 1
        else { return }
        await seekToChapter(href: chapters[currentIndex + 1].href)
    }

    public func skipToPreviousChapter() async {
        guard let chapters = metadata?.chapters,
            let currentIndex = await getCurrentChapterIndex(),
            currentIndex > 0
        else { return }
        await seekToChapter(href: chapters[currentIndex - 1].href)
    }

    private func startNowPlayingUpdateTimer() {
        stopNowPlayingUpdateTimer()

        let timer = Timer(timeInterval: 30.0, repeats: true) { _ in
            Task { @AudiobookActor in
                await AudiobookActor.shared.refreshNowPlayingInfo()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingUpdateTimer = timer
    }

    private func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    private func stopNowPlayingUpdateTimer() {
        nowPlayingUpdateTimer?.invalidate()
        nowPlayingUpdateTimer = nil
    }
    #endif

    public func cleanup() async {
        player?.stop()
        player = nil
        metadata = nil
        currentFileURL = nil
        stateObservers.removeAll()

        #if os(iOS)
        stopNowPlayingUpdateTimer()
        clearRemoteCommands()
        artworkImage = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            debugLog("[AudiobookActor] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}
