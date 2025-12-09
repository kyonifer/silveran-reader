#if canImport(AVFoundation)
import AVFoundation
import Foundation

#if os(iOS)
import MediaPlayer
import UIKit
#endif

// MARK: - Error Types

public enum SMILPlayerError: Error, LocalizedError {
    case noMediaOverlay
    case bookNotLoaded
    case audioLoadFailed(String)
    case invalidPosition

    public var errorDescription: String? {
        switch self {
        case .noMediaOverlay:
            return "Book does not contain audio narration"
        case .bookNotLoaded:
            return "No book is currently loaded"
        case .audioLoadFailed(let reason):
            return "Failed to load audio: \(reason)"
        case .invalidPosition:
            return "Invalid playback position"
        }
    }
}

// MARK: - State Snapshot

public struct SMILPlaybackState: Sendable {
    public let isPlaying: Bool
    public let currentTime: Double
    public let duration: Double
    public let currentSectionIndex: Int
    public let currentEntryIndex: Int
    public let currentFragment: String
    public let chapterLabel: String?
    public let chapterElapsed: Double
    public let chapterTotal: Double
    public let bookElapsed: Double
    public let bookTotal: Double
    public let playbackRate: Double
    public let volume: Double
    public let bookId: String?

    public init(
        isPlaying: Bool,
        currentTime: Double,
        duration: Double,
        currentSectionIndex: Int,
        currentEntryIndex: Int,
        currentFragment: String,
        chapterLabel: String?,
        chapterElapsed: Double,
        chapterTotal: Double,
        bookElapsed: Double,
        bookTotal: Double,
        playbackRate: Double,
        volume: Double,
        bookId: String?
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.currentSectionIndex = currentSectionIndex
        self.currentEntryIndex = currentEntryIndex
        self.currentFragment = currentFragment
        self.chapterLabel = chapterLabel
        self.chapterElapsed = chapterElapsed
        self.chapterTotal = chapterTotal
        self.bookElapsed = bookElapsed
        self.bookTotal = bookTotal
        self.playbackRate = playbackRate
        self.volume = volume
        self.bookId = bookId
    }
}

// MARK: - Global Actor

@globalActor
public actor SMILPlayerActor {
    public static let shared = SMILPlayerActor()

    // MARK: - Player State

    private var player: AVAudioPlayer?
    private var bookStructure: [SectionInfo] = []
    private var epubPath: URL?
    private var bookId: String?
    private var bookTitle: String?
    private var bookAuthor: String?

    private var currentSectionIndex: Int = 0
    private var currentEntryIndex: Int = 0
    private var currentAudioFile: String = ""
    private var currentEntryBeginTime: Double = 0
    private var currentEntryEndTime: Double = 0

    private var isPlaying: Bool = false
    private var playbackRate: Double = 1.0
    private var volume: Double = 1.0

    private var updateTimer: Timer?
    private var lastPausedWhilePlayingTime: Date?
    private var lastProgressNotifyTime: Date = .distantPast

    // MARK: - Observer Pattern

    private var stateObservers: [UUID: @Sendable @MainActor (SMILPlaybackState) -> Void] = [:]

    // MARK: - iOS Specific

    #if os(iOS)
    private var audioManagerIos: SMILAudioManagerIos?
    private var coverImage: UIImage?
    private var nowPlayingUpdateTimer: Timer?
    private var audioSessionObserversConfigured = false
    #endif

    // MARK: - Initialization

    private init() {}

    // MARK: - Book Loading

    public func loadBook(
        epubPath: URL,
        bookId: String,
        title: String?,
        author: String?
    ) async throws {
        debugLog("[SMILPlayerActor] Loading book: \(bookId) from \(epubPath.path)")

        await cleanup()

        let structure = try SMILParser.parseEPUB(at: epubPath)

        guard structure.contains(where: { !$0.mediaOverlay.isEmpty }) else {
            throw SMILPlayerError.noMediaOverlay
        }

        self.bookStructure = structure
        self.epubPath = epubPath
        self.bookId = bookId
        self.bookTitle = title
        self.bookAuthor = author
        self.currentSectionIndex = 0
        self.currentEntryIndex = 0

        #if os(iOS)
        setupAudioSession()
        configureAudioSessionObservers()
        await setupAudioManagerIos()
        #endif

        debugLog("[SMILPlayerActor] Book loaded with \(structure.count) sections")
        await notifyStateChange()
    }

    public func getBookStructure() -> [SectionInfo] {
        return bookStructure
    }

    public func getLoadedBookId() -> String? {
        return bookId
    }

    // MARK: - Cover Image (iOS)

    #if os(iOS)
    public func setCoverImage(_ image: UIImage?) async {
        coverImage = image
        let manager = audioManagerIos
        await MainActor.run {
            manager?.coverImage = image
        }
        updateNowPlayingInfo()
    }
    #endif

    // MARK: - Playback Control

    public func play() async throws {
        guard !bookStructure.isEmpty else {
            throw SMILPlayerError.bookNotLoaded
        }

        if player == nil {
            try await loadCurrentEntry()
        }

        guard let player = player else {
            throw SMILPlayerError.audioLoadFailed("Player not initialized")
        }

        #if os(iOS)
        ensureAudioSessionActive()
        #endif

        player.play()
        isPlaying = true
        startUpdateTimer()

        #if os(iOS)
        startNowPlayingUpdateTimer()
        #endif

        debugLog("[SMILPlayerActor] Playing")
        await notifyStateChange()
    }

    public func pause() async {
        guard let player = player else { return }

        if isPlaying {
            lastPausedWhilePlayingTime = Date()
        }

        player.pause()
        isPlaying = false
        stopUpdateTimer()

        #if os(iOS)
        stopNowPlayingUpdateTimer()
        updateNowPlayingInfo()
        #endif

        debugLog("[SMILPlayerActor] Paused")
        await notifyStateChange()
    }

    public func togglePlayPause() async throws {
        if isPlaying {
            await pause()
        } else {
            try await play()
        }
    }

    // MARK: - Seeking

    public func seekToEntry(sectionIndex: Int, entryIndex: Int) async throws {
        guard sectionIndex >= 0 && sectionIndex < bookStructure.count else {
            throw SMILPlayerError.invalidPosition
        }

        let section = bookStructure[sectionIndex]
        guard entryIndex >= 0 && entryIndex < section.mediaOverlay.count else {
            throw SMILPlayerError.invalidPosition
        }

        let entry = section.mediaOverlay[entryIndex]
        await setCurrentEntry(
            sectionIndex: sectionIndex,
            entryIndex: entryIndex,
            audioFile: entry.audioFile,
            beginTime: entry.begin,
            endTime: entry.end
        )
    }

    public func seekToFragment(sectionIndex: Int, textId: String) async -> Bool {
        guard sectionIndex >= 0 && sectionIndex < bookStructure.count else {
            debugLog("[SMILPlayerActor] seekToFragment - invalid section: \(sectionIndex)")
            return false
        }

        let section = bookStructure[sectionIndex]
        guard let entryIndex = section.mediaOverlay.firstIndex(where: { $0.textId == textId }) else {
            debugLog("[SMILPlayerActor] seekToFragment - textId not found: \(textId)")
            return false
        }

        let entry = section.mediaOverlay[entryIndex]
        await setCurrentEntry(
            sectionIndex: sectionIndex,
            entryIndex: entryIndex,
            audioFile: entry.audioFile,
            beginTime: entry.begin,
            endTime: entry.end
        )
        return true
    }

    public func skipForward(seconds: Double = 15) async {
        guard let player = player else { return }
        let newTime = min(player.currentTime + seconds, player.duration)
        player.currentTime = newTime
        reconcileEntryFromTime(newTime)
        await notifyStateChange()
    }

    public func skipBackward(seconds: Double = 15) async {
        guard let player = player else { return }
        let newTime = max(player.currentTime - seconds, 0)
        player.currentTime = newTime
        reconcileEntryFromTime(newTime)
        await notifyStateChange()
    }

    // MARK: - Settings

    public func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        player?.rate = Float(rate)
        debugLog("[SMILPlayerActor] Playback rate set to \(rate)")
        await notifyStateChange()
    }

    public func setVolume(_ newVolume: Double) async {
        volume = newVolume
        player?.volume = Float(newVolume)
        debugLog("[SMILPlayerActor] Volume set to \(newVolume)")
    }

    // MARK: - State Access

    public func getCurrentState() async -> SMILPlaybackState? {
        guard !bookStructure.isEmpty else { return nil }
        return buildCurrentState()
    }

    public func getCurrentEntry() -> SMILEntry? {
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }
        return section.mediaOverlay[currentEntryIndex]
    }

    public func getCurrentPosition() -> (sectionIndex: Int, entryIndex: Int) {
        return (currentSectionIndex, currentEntryIndex)
    }

    // MARK: - Observer Pattern

    public func addStateObserver(
        id: UUID = UUID(),
        observer: @escaping @Sendable @MainActor (SMILPlaybackState) -> Void
    ) async -> UUID {
        stateObservers[id] = observer
        if let state = buildCurrentState() {
            await observer(state)
        }
        return id
    }

    public func removeStateObserver(id: UUID) async {
        stateObservers.removeValue(forKey: id)
    }

    // MARK: - Background Sync

    public func getBackgroundSyncData() -> AudioPositionSyncData? {
        guard !bookStructure.isEmpty else { return nil }
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }

        let entry = section.mediaOverlay[currentEntryIndex]

        return AudioPositionSyncData(
            sectionIndex: currentSectionIndex,
            entryIndex: currentEntryIndex,
            currentTime: player?.currentTime ?? 0,
            audioFile: currentAudioFile,
            href: entry.textHref,
            fragment: entry.textId
        )
    }

    public func reconcilePositionFromPlayer() {
        guard let player = player else { return }
        reconcileEntryFromTime(player.currentTime)
    }

    // MARK: - Cleanup

    public func cleanup() async {
        debugLog("[SMILPlayerActor] Cleanup")

        stopUpdateTimer()
        player?.stop()
        player = nil

        bookStructure = []
        epubPath = nil
        bookId = nil
        bookTitle = nil
        bookAuthor = nil
        currentSectionIndex = 0
        currentEntryIndex = 0
        currentAudioFile = ""
        isPlaying = false

        stateObservers.removeAll()

        #if os(iOS)
        stopNowPlayingUpdateTimer()
        await cleanupAudioManagerIos()
        removeAudioSessionObservers()
        coverImage = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            debugLog("[SMILPlayerActor] Failed to deactivate audio session: \(error)")
        }
        #endif
    }

    // MARK: - Private: Entry Management

    private func setCurrentEntry(
        sectionIndex: Int,
        entryIndex: Int,
        audioFile: String,
        beginTime: Double,
        endTime: Double
    ) async {
        debugLog(
            "[SMILPlayerActor] setCurrentEntry: section=\(sectionIndex), entry=\(entryIndex), file=\(audioFile)"
        )

        let wasRecentlyPlaying: Bool
        if let pauseTime = lastPausedWhilePlayingTime {
            let elapsed = Date().timeIntervalSince(pauseTime)
            wasRecentlyPlaying = elapsed < 0.5
        } else {
            wasRecentlyPlaying = false
        }

        currentSectionIndex = sectionIndex
        currentEntryIndex = entryIndex
        currentEntryBeginTime = beginTime
        currentEntryEndTime = endTime

        if audioFile != currentAudioFile {
            currentAudioFile = audioFile
            await loadAudioFile(audioFile)
        }

        if let player = player {
            player.currentTime = beginTime

            if wasRecentlyPlaying {
                lastPausedWhilePlayingTime = nil
                player.play()
                isPlaying = true
                startUpdateTimer()
                #if os(iOS)
                startNowPlayingUpdateTimer()
                #endif
            }
        }

        await notifyStateChange()
    }

    private func loadCurrentEntry() async throws {
        guard currentSectionIndex < bookStructure.count else {
            throw SMILPlayerError.invalidPosition
        }

        let section = bookStructure[currentSectionIndex]

        if section.mediaOverlay.isEmpty {
            if let nextSection = bookStructure.first(where: { $0.index > currentSectionIndex && !$0.mediaOverlay.isEmpty }) {
                currentSectionIndex = nextSection.index
                currentEntryIndex = 0
                let entry = nextSection.mediaOverlay[0]
                currentAudioFile = entry.audioFile
                currentEntryBeginTime = entry.begin
                currentEntryEndTime = entry.end
            } else {
                throw SMILPlayerError.noMediaOverlay
            }
        } else if currentEntryIndex >= section.mediaOverlay.count {
            currentEntryIndex = 0
            let entry = section.mediaOverlay[0]
            currentAudioFile = entry.audioFile
            currentEntryBeginTime = entry.begin
            currentEntryEndTime = entry.end
        } else {
            let entry = section.mediaOverlay[currentEntryIndex]
            currentAudioFile = entry.audioFile
            currentEntryBeginTime = entry.begin
            currentEntryEndTime = entry.end
        }

        await loadAudioFile(currentAudioFile)
        player?.currentTime = currentEntryBeginTime
    }

    private func loadAudioFile(_ relativeAudioFile: String) async {
        guard let epubPath = epubPath else {
            debugLog("[SMILPlayerActor] No EPUB path for audio loading")
            return
        }

        debugLog("[SMILPlayerActor] Loading audio file: \(relativeAudioFile)")

        do {
            let audioData = try await FilesystemActor.shared.extractAudioData(
                from: epubPath,
                audioPath: relativeAudioFile
            )
            let newPlayer = try AVAudioPlayer(data: audioData)
            newPlayer.enableRate = true
            newPlayer.rate = Float(playbackRate)
            newPlayer.volume = Float(volume)
            newPlayer.prepareToPlay()
            self.player = newPlayer
            debugLog("[SMILPlayerActor] Audio loaded, duration: \(newPlayer.duration)s")
        } catch {
            debugLog("[SMILPlayerActor] Failed to load audio: \(error)")
        }
    }

    // MARK: - Private: Timer

    private func startUpdateTimer() {
        stopUpdateTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.timerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        debugLog("[SMILPlayerActor] Update timer started")
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func timerFired() async {
        guard let player = player, isPlaying else { return }

        let currentTime = player.currentTime
        let tolerance = 0.02
        let shouldAdvance = currentTime >= currentEntryEndTime - tolerance

        if shouldAdvance {
            await advanceToNextEntry()
        }

        let now = Date()
        if now.timeIntervalSince(lastProgressNotifyTime) >= 0.2 {
            lastProgressNotifyTime = now
            await notifyStateChange()
        }
    }

    // MARK: - Private: Entry Navigation

    private func advanceToNextEntry() async {
        guard currentSectionIndex < bookStructure.count else {
            debugLog("[SMILPlayerActor] End of book - currentSectionIndex \(currentSectionIndex) >= count \(bookStructure.count)")
            await pause()
            return
        }

        let section = bookStructure[currentSectionIndex]
        let nextEntryIndex = currentEntryIndex + 1

        debugLog("[SMILPlayerActor] advanceToNextEntry: section=\(currentSectionIndex), nextEntry=\(nextEntryIndex), overlayCount=\(section.mediaOverlay.count)")

        if nextEntryIndex < section.mediaOverlay.count {
            let nextEntry = section.mediaOverlay[nextEntryIndex]
            currentEntryIndex = nextEntryIndex
            currentEntryBeginTime = nextEntry.begin
            currentEntryEndTime = nextEntry.end

            if nextEntry.audioFile != currentAudioFile {
                currentAudioFile = nextEntry.audioFile
                await loadAudioFile(nextEntry.audioFile)
                player?.currentTime = nextEntry.begin
                if isPlaying {
                    player?.play()
                }
            }

            debugLog("[SMILPlayerActor] Advanced to entry \(nextEntryIndex) in section \(currentSectionIndex)")
            await notifyStateChange()
        } else {
            let nextSectionIndex = currentSectionIndex + 1
            debugLog("[SMILPlayerActor] Section \(currentSectionIndex) complete, looking for next section >= \(nextSectionIndex)")
            if let nextSection = bookStructure.first(where: { $0.index >= nextSectionIndex && !$0.mediaOverlay.isEmpty }) {
                let nextEntry = nextSection.mediaOverlay[0]
                currentSectionIndex = nextSection.index
                currentEntryIndex = 0
                currentEntryBeginTime = nextEntry.begin
                currentEntryEndTime = nextEntry.end
                currentAudioFile = nextEntry.audioFile

                await loadAudioFile(nextEntry.audioFile)
                player?.currentTime = nextEntry.begin
                if isPlaying {
                    player?.play()
                }

                debugLog("[SMILPlayerActor] Advanced to section \(nextSection.index)")
                await notifyStateChange()
            } else {
                debugLog("[SMILPlayerActor] End of book reached")
                await pause()
            }
        }
    }

    private func reconcileEntryFromTime(_ time: Double) {
        guard currentSectionIndex < bookStructure.count else { return }

        let section = bookStructure[currentSectionIndex]
        for (index, entry) in section.mediaOverlay.enumerated() {
            if time >= entry.begin && time < entry.end {
                if index != currentEntryIndex {
                    currentEntryIndex = index
                    currentEntryBeginTime = entry.begin
                    currentEntryEndTime = entry.end
                }
                return
            }
        }
    }

    // MARK: - Private: State Building

    private func buildCurrentState() -> SMILPlaybackState? {
        guard !bookStructure.isEmpty else { return nil }

        let currentTime = player?.currentTime ?? 0
        let duration = player?.duration ?? 0

        var chapterLabel: String? = nil
        var chapterElapsed: Double = 0
        var chapterTotal: Double = 0

        if currentSectionIndex < bookStructure.count {
            let section = bookStructure[currentSectionIndex]
            chapterLabel = section.label

            if !section.mediaOverlay.isEmpty {
                if let lastEntry = section.mediaOverlay.last {
                    chapterTotal = lastEntry.cumSumAtEnd
                }
                if currentEntryIndex < section.mediaOverlay.count {
                    let entry = section.mediaOverlay[currentEntryIndex]
                    let prevCumSum = currentEntryIndex > 0
                        ? section.mediaOverlay[currentEntryIndex - 1].cumSumAtEnd
                        : 0
                    let timeInEntry = currentTime - entry.begin
                    chapterElapsed = prevCumSum + max(0, timeInEntry)
                }
            }
        }

        var bookElapsed: Double = 0
        var bookTotal: Double = 0

        for section in bookStructure.reversed() {
            if !section.mediaOverlay.isEmpty, let lastEntry = section.mediaOverlay.last {
                bookTotal = lastEntry.cumSumAtEnd
                break
            }
        }

        if currentSectionIndex < bookStructure.count {
            let section = bookStructure[currentSectionIndex]
            if !section.mediaOverlay.isEmpty {
                if let prevSection = bookStructure.prefix(currentSectionIndex).last(where: { !$0.mediaOverlay.isEmpty }),
                   let prevLastEntry = prevSection.mediaOverlay.last {
                    bookElapsed = prevLastEntry.cumSumAtEnd + chapterElapsed
                } else {
                    bookElapsed = chapterElapsed
                }
            }
        }

        let currentFragment: String
        if currentSectionIndex < bookStructure.count {
            let section = bookStructure[currentSectionIndex]
            if currentEntryIndex < section.mediaOverlay.count {
                let entry = section.mediaOverlay[currentEntryIndex]
                currentFragment = "\(entry.textHref)#\(entry.textId)"
            } else {
                currentFragment = section.id
            }
        } else {
            currentFragment = ""
        }

        return SMILPlaybackState(
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            currentSectionIndex: currentSectionIndex,
            currentEntryIndex: currentEntryIndex,
            currentFragment: currentFragment,
            chapterLabel: chapterLabel,
            chapterElapsed: chapterElapsed,
            chapterTotal: chapterTotal,
            bookElapsed: bookElapsed,
            bookTotal: bookTotal,
            playbackRate: playbackRate,
            volume: volume,
            bookId: bookId
        )
    }

    private func notifyStateChange() async {
        guard let state = buildCurrentState() else { return }

        #if os(iOS)
        updateNowPlayingInfo()
        #endif

        for observer in stateObservers.values {
            await observer(state)
        }
    }

    // MARK: - iOS Audio Session

    #if os(iOS)
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[SMILPlayerActor] Audio session configured")
        } catch {
            debugLog("[SMILPlayerActor] Failed to configure audio session: \(error)")
        }
    }

    private func ensureAudioSessionActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            debugLog("[SMILPlayerActor] Failed to re-activate audio session: \(error)")
        }
    }

    private func configureAudioSessionObservers() {
        guard !audioSessionObserversConfigured else { return }

        let session = AVAudioSession.sharedInstance()

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self = self else { return }
            self.handleAudioSessionInterruption(notification)
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self = self else { return }
            self.handleAudioRouteChange(notification)
        }

        audioSessionObserversConfigured = true
        debugLog("[SMILPlayerActor] Audio session observers registered")
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

        Task { @SMILPlayerActor in
            switch type {
            case .began:
                debugLog("[SMILPlayerActor] Audio session interrupted - pausing")
                await SMILPlayerActor.shared.pause()
            case .ended:
                if shouldResume {
                    debugLog("[SMILPlayerActor] Audio interruption ended - resuming")
                    try? await SMILPlayerActor.shared.play()
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

        Task { @SMILPlayerActor in
            switch reason {
            case .oldDeviceUnavailable:
                debugLog("[SMILPlayerActor] Audio route lost - pausing")
                await SMILPlayerActor.shared.pause()
            case .newDeviceAvailable:
                debugLog("[SMILPlayerActor] New audio device available")
            default:
                break
            }
        }
    }

    private func removeAudioSessionObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        audioSessionObserversConfigured = false
    }

    // MARK: - iOS Audio Manager

    private func setupAudioManagerIos() async {
        let title = bookTitle
        let author = bookAuthor
        let cover = coverImage
        let manager = await MainActor.run {
            let m = SMILAudioManagerIos()
            m.bookTitle = title
            m.bookAuthor = author
            m.coverImage = cover
            return m
        }
        self.audioManagerIos = manager
        debugLog("[SMILPlayerActor] AudioManagerIos created")
    }

    private func cleanupAudioManagerIos() async {
        let manager = audioManagerIos
        await MainActor.run {
            manager?.cleanup()
        }
        audioManagerIos = nil
    }

    // MARK: - iOS Now Playing

    private func updateNowPlayingInfo() {
        guard !bookStructure.isEmpty else {
            let manager = audioManagerIos
            Task { @MainActor in
                manager?.clearNowPlayingInfo()
            }
            return
        }

        let state = buildCurrentState()
        let manager = audioManagerIos

        Task { @MainActor in
            manager?.updateNowPlayingInfo(
                currentTime: state?.chapterElapsed ?? 0,
                duration: state?.chapterTotal ?? 0,
                chapterLabel: state?.chapterLabel ?? "Playing",
                isPlaying: state?.isPlaying ?? false,
                playbackRate: state?.playbackRate ?? 1.0
            )
        }
    }

    private func startNowPlayingUpdateTimer() {
        stopNowPlayingUpdateTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.updateNowPlayingIfPlaying()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingUpdateTimer = timer
    }

    private func updateNowPlayingIfPlaying() {
        if isPlaying {
            updateNowPlayingInfo()
        }
    }

    private func stopNowPlayingUpdateTimer() {
        nowPlayingUpdateTimer?.invalidate()
        nowPlayingUpdateTimer = nil
    }
    #endif
}

// MARK: - iOS Audio Manager Helper

#if os(iOS)
@MainActor
class SMILAudioManagerIos {
    var bookTitle: String?
    var bookAuthor: String?
    var coverImage: UIImage? {
        didSet {
            cachedArtwork = coverImage.map { createArtwork(from: $0) }
        }
    }

    private var cachedArtwork: MPMediaItemArtwork?

    init() {
        debugLog("[SMILAudioManagerIos] Initializing")
        setupRemoteCommandCenter()
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManagerIos] Remote play command")
                try? await SMILPlayerActor.shared.play()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManagerIos] Remote pause command")
                await SMILPlayerActor.shared.pause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManagerIos] Remote skip forward command")
                await SMILPlayerActor.shared.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManagerIos] Remote skip backward command")
                await SMILPlayerActor.shared.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = false

        debugLog("[SMILAudioManagerIos] Remote commands configured")
    }

    func updateNowPlayingInfo(
        currentTime: Double,
        duration: Double,
        chapterLabel: String,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        var info = [String: Any]()

        info[MPMediaItemPropertyTitle] = bookTitle ?? "Silveran Reader"
        info[MPMediaItemPropertyArtist] = chapterLabel
        info[MPMediaItemPropertyAlbumTitle] = bookAuthor ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func cleanup() {
        debugLog("[SMILAudioManagerIos] Cleanup")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }

    nonisolated private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
#endif
#endif
