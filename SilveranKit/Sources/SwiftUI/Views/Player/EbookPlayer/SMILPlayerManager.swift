import Foundation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AudioPositionSyncData {
    let sectionIndex: Int
    let entryIndex: Int
    let currentTime: Double
    let audioFile: String
    let href: String
    let fragment: String
}

#if os(iOS)
private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}
#elseif os(macOS)
private func createArtwork(from image: NSImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}
#endif

enum RemoteCommand {
    case play
    case pause
    case skipForward(seconds: Double)
    case skipBackward(seconds: Double)
    case seekTo(position: Double)
}

@MainActor
protocol SMILPlayerManagerDelegate: AnyObject {
    func smilPlayerDidAdvanceToEntry(sectionIndex: Int, entryIndex: Int, entry: SMILEntry)
    func smilPlayerDidFinishBook()
    func smilPlayerDidUpdateTime(currentTime: Double, sectionIndex: Int, entryIndex: Int)
    func smilPlayerShouldAdvanceToNextSection(fromSection: Int) -> Bool
    func smilPlayerRemoteCommandReceived(command: RemoteCommand)
}

@MainActor
@Observable
class SMILPlayerManager {
    // MARK: - State

    enum PlayerState {
        case idle
        case loading
        case ready
        case playing
        case paused
    }

    private(set) var state: PlayerState = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var lastPausedWhilePlayingTime: Date?

    // MARK: - SMIL Tracking

    private var bookStructure: [SectionInfo] = []
    private var currentSectionIndex: Int = 0
    private var currentEntryIndex: Int = 0
    private var currentAudioFile: String = ""
    private var currentEntryBeginTime: Double = 0
    private var currentEntryEndTime: Double = 0
    private var epubPath: URL?

    // MARK: - Metadata for lockscreen

    var bookTitle: String?
    var bookAuthor: String?
    private var cachedArtwork: MPMediaItemArtwork?

    #if os(iOS)
    var coverImage: UIImage? {
        didSet {
            cachedArtwork = coverImage.map { createArtwork(from: $0) }
        }
    }
    #elseif os(macOS)
    var coverImage: NSImage? {
        didSet {
            cachedArtwork = coverImage.map { createArtwork(from: $0) }
        }
    }
    #endif

    // MARK: - AVFoundation

    private var audioPlayer: AVAudioPlayer?
    private var updateTimer: Timer?
    private var currentPlaybackRate: Float = 1.0

    // MARK: - Delegate

    weak var delegate: SMILPlayerManagerDelegate?
    private var lastProgressUpdateTime: Date = .distantPast

    // MARK: - Initialization

    init(bookStructure: [SectionInfo], epubPath: URL?, initialPlaybackRate: Double = 1.0) {
        self.bookStructure = bookStructure
        self.epubPath = epubPath
        self.currentPlaybackRate = Float(initialPlaybackRate)
        debugLog("[SMILPlayerManager] Initialized with \(bookStructure.count) sections, epubPath: \(epubPath?.path ?? "nil"), rate: \(initialPlaybackRate)")

        setupAudioSession()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[SMILPlayerManager] Audio session configured for playback")
        } catch {
            debugLog("[SMILPlayerManager] Failed to configure audio session: \(error)")
        }
        #endif
    }

    // MARK: - Entry Management

    func setCurrentEntry(sectionIndex: Int, entryIndex: Int, audioFile: String, beginTime: Double, endTime: Double) async {
        debugLog("[SMILPlayerManager] setCurrentEntry: section=\(sectionIndex), entry=\(entryIndex), file=\(audioFile), begin=\(beginTime), end=\(endTime)")

        // Check if we were recently playing (paused within last 500ms for seek)
        let wasRecentlyPlaying: Bool
        if let pauseTime = lastPausedWhilePlayingTime {
            let elapsed = Date().timeIntervalSince(pauseTime)
            wasRecentlyPlaying = elapsed < 0.5
            debugLog("[SMILPlayerManager] Time since pause: \(elapsed)s, wasRecentlyPlaying=\(wasRecentlyPlaying)")
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

        if let player = audioPlayer {
            debugLog("[SMILPlayerManager] Seeking to entry begin time: \(beginTime)")
            player.currentTime = beginTime
            currentTime = beginTime

            if wasRecentlyPlaying {
                debugLog("[SMILPlayerManager] Resuming playback after seek")
                lastPausedWhilePlayingTime = nil
                play()
            }
        }

        updateNowPlayingInfo()
    }

    /// Seek to a specific fragment by textId within a section
    func seekToFragment(sectionIndex: Int, textId: String) async -> Bool {
        guard sectionIndex >= 0 && sectionIndex < bookStructure.count else {
            debugLog("[SMILPlayerManager] seekToFragment - invalid section: \(sectionIndex)")
            return false
        }

        let section = bookStructure[sectionIndex]
        guard let entryIndex = section.mediaOverlay.firstIndex(where: { $0.textId == textId }) else {
            debugLog("[SMILPlayerManager] seekToFragment - textId not found: \(textId)")
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

    func getCurrentEntry() -> SMILEntry? {
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }
        return section.mediaOverlay[currentEntryIndex]
    }

    func getCurrentPosition() -> (sectionIndex: Int, entryIndex: Int) {
        return (currentSectionIndex, currentEntryIndex)
    }

    // MARK: - Audio Loading

    private func loadAudioFile(_ relativeAudioFile: String) async {
        guard let epubPath = epubPath else {
            debugLog("[SMILPlayerManager] No EPUB path for audio loading")
            state = .idle
            return
        }

        debugLog("[SMILPlayerManager] Loading audio file from EPUB: \(relativeAudioFile)")
        state = .loading

        do {
            let audioData = try await FilesystemActor.shared.extractAudioData(
                from: epubPath,
                audioPath: relativeAudioFile
            )
            audioPlayer = try AVAudioPlayer(data: audioData)
            audioPlayer?.enableRate = true
            audioPlayer?.rate = currentPlaybackRate
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            state = .ready
            debugLog("[SMILPlayerManager] Audio loaded from EPUB, duration: \(duration)s, rate: \(currentPlaybackRate)")
        } catch {
            debugLog("[SMILPlayerManager] Failed to load audio from EPUB: \(error)")
            state = .idle
        }
    }

    // MARK: - Playback Control

    func play() {
        guard let player = audioPlayer else {
            debugLog("[SMILPlayerManager] play() - no audio player")
            return
        }

        debugLog("[SMILPlayerManager] play()")
        player.play()
        state = .playing
        startUpdateTimer()
    }

    func pause() {
        guard let player = audioPlayer else { return }

        // Track when we were playing before pausing (for seek-resume detection)
        if state == .playing {
            lastPausedWhilePlayingTime = Date()
        }

        debugLog("[SMILPlayerManager] pause()")
        player.pause()
        state = .paused
        stopUpdateTimer()
    }

    func seek(to time: Double) {
        guard let player = audioPlayer else {
            debugLog("[SMILPlayerManager] seek(to: \(time)) - no audio player")
            return
        }

        debugLog("[SMILPlayerManager] seek(to: \(time)), player.duration=\(player.duration)")
        player.currentTime = time
        currentTime = time
    }

    func setVolume(_ volume: Double) {
        audioPlayer?.volume = Float(volume)
        debugLog("[SMILPlayerManager] setVolume(\(volume))")
    }

    func setPlaybackRate(_ rate: Double) {
        currentPlaybackRate = Float(rate)
        audioPlayer?.rate = currentPlaybackRate
        debugLog("[SMILPlayerManager] setPlaybackRate(\(rate))")
    }

    // MARK: - Update Timer

    private func startUpdateTimer() {
        stopUpdateTimer()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerFired()
            }
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func timerFired() {
        guard let player = audioPlayer, state == .playing else { return }

        let prevTime = currentTime
        currentTime = player.currentTime

        // Detect if audio file finished (time wrapped to 0 after being near end)
        if prevTime > 0 && currentTime == 0 && prevTime >= duration - 0.5 {
            debugLog("[SMILPlayerManager] Audio ended (reached end of file)")
            advanceToNextEntry()
            return
        }

        // Backup: detect if player stopped (isPlaying becomes false at end of file)
        if !player.isPlaying && currentTime >= duration - 0.1 {
            debugLog("[SMILPlayerManager] Audio playback finished")
            advanceToNextEntry()
            return
        }

        // Check if we've passed the current entry boundary (use >= for exact match)
        if currentTime >= currentEntryEndTime {
            advanceToNextEntry()
        }

        // Send time updates to delegate (throttled to ~5 per second)
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdateTime) >= 0.2 {
            lastProgressUpdateTime = now
            delegate?.smilPlayerDidUpdateTime(
                currentTime: currentTime,
                sectionIndex: currentSectionIndex,
                entryIndex: currentEntryIndex
            )
        }

        updateNowPlayingInfo()
    }

    // MARK: - Background Sync

    /// Get current audio position data for syncing view after returning from background
    func getBackgroundSyncData() -> AudioPositionSyncData? {
        guard state == .playing || state == .paused else { return nil }
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }

        let entry = section.mediaOverlay[currentEntryIndex]

        debugLog("[SMILPlayerManager] getBackgroundSyncData: section=\(currentSectionIndex), entry=\(currentEntryIndex), fragment=\(entry.textId)")

        return AudioPositionSyncData(
            sectionIndex: currentSectionIndex,
            entryIndex: currentEntryIndex,
            currentTime: currentTime,
            audioFile: currentAudioFile,
            href: entry.textHref,
            fragment: entry.textId
        )
    }

    // MARK: - Entry Navigation

    /// Advance to the next SMIL entry (called by timer or externally)
    func advanceToNextEntry() {
        guard currentSectionIndex < bookStructure.count else {
            debugLog("[SMILPlayerManager] End of book")
            pause()
            delegate?.smilPlayerDidFinishBook()
            return
        }

        let section = bookStructure[currentSectionIndex]
        let nextEntryIndex = currentEntryIndex + 1

        if nextEntryIndex < section.mediaOverlay.count {
            let nextEntry = section.mediaOverlay[nextEntryIndex]
            currentEntryIndex = nextEntryIndex
            currentEntryBeginTime = nextEntry.begin
            currentEntryEndTime = nextEntry.end

            if nextEntry.audioFile != currentAudioFile {
                Task {
                    currentAudioFile = nextEntry.audioFile
                    await loadAudioFile(nextEntry.audioFile)
                    seek(to: nextEntry.begin)
                    play()
                }
            }

            debugLog("[SMILPlayerManager] Advanced to entry \(nextEntryIndex) in section \(currentSectionIndex)")
            delegate?.smilPlayerDidAdvanceToEntry(sectionIndex: currentSectionIndex, entryIndex: currentEntryIndex, entry: nextEntry)
        } else {
            if delegate?.smilPlayerShouldAdvanceToNextSection(fromSection: currentSectionIndex) == false {
                debugLog("[SMILPlayerManager] Delegate blocked section advance (sleep timer?)")
                pause()
                return
            }

            let nextSectionIndex = currentSectionIndex + 1
            if nextSectionIndex < bookStructure.count {
                let nextSection = bookStructure[nextSectionIndex]
                if !nextSection.mediaOverlay.isEmpty {
                    let nextEntry = nextSection.mediaOverlay[0]
                    currentSectionIndex = nextSectionIndex
                    currentEntryIndex = 0
                    currentEntryBeginTime = nextEntry.begin
                    currentEntryEndTime = nextEntry.end

                    Task {
                        currentAudioFile = nextEntry.audioFile
                        await loadAudioFile(nextEntry.audioFile)
                        seek(to: nextEntry.begin)
                        play()
                    }

                    debugLog("[SMILPlayerManager] Advanced to section \(nextSectionIndex)")
                    delegate?.smilPlayerDidAdvanceToEntry(sectionIndex: currentSectionIndex, entryIndex: currentEntryIndex, entry: nextEntry)
                } else {
                    debugLog("[SMILPlayerManager] End of book reached (next section has no audio)")
                    pause()
                    delegate?.smilPlayerDidFinishBook()
                }
            } else {
                debugLog("[SMILPlayerManager] End of book reached")
                pause()
                delegate?.smilPlayerDidFinishBook()
            }
        }

        updateNowPlayingInfo()
    }

    /// Go back to the previous SMIL entry
    func goToPreviousEntry() {
        if currentEntryIndex > 0 {
            let section = bookStructure[currentSectionIndex]
            let prevEntry = section.mediaOverlay[currentEntryIndex - 1]
            currentEntryIndex -= 1
            currentEntryBeginTime = prevEntry.begin
            currentEntryEndTime = prevEntry.end

            if prevEntry.audioFile != currentAudioFile {
                Task {
                    currentAudioFile = prevEntry.audioFile
                    await loadAudioFile(prevEntry.audioFile)
                    seek(to: prevEntry.begin)
                    if state == .playing { play() }
                }
            } else {
                seek(to: prevEntry.begin)
            }

            debugLog("[SMILPlayerManager] Went back to entry \(currentEntryIndex) in section \(currentSectionIndex)")
            delegate?.smilPlayerDidAdvanceToEntry(sectionIndex: currentSectionIndex, entryIndex: currentEntryIndex, entry: prevEntry)
        } else if currentSectionIndex > 0 {
            var prevSectionIndex = currentSectionIndex - 1
            while prevSectionIndex >= 0 && bookStructure[prevSectionIndex].mediaOverlay.isEmpty {
                prevSectionIndex -= 1
            }

            if prevSectionIndex >= 0 {
                let prevSection = bookStructure[prevSectionIndex]
                let lastEntry = prevSection.mediaOverlay[prevSection.mediaOverlay.count - 1]
                currentSectionIndex = prevSectionIndex
                currentEntryIndex = prevSection.mediaOverlay.count - 1
                currentEntryBeginTime = lastEntry.begin
                currentEntryEndTime = lastEntry.end

                Task {
                    currentAudioFile = lastEntry.audioFile
                    await loadAudioFile(lastEntry.audioFile)
                    seek(to: lastEntry.begin)
                    if state == .playing { play() }
                }

                debugLog("[SMILPlayerManager] Went back to section \(prevSectionIndex), entry \(currentEntryIndex)")
                delegate?.smilPlayerDidAdvanceToEntry(sectionIndex: currentSectionIndex, entryIndex: currentEntryIndex, entry: lastEntry)
            }
        } else {
            seek(to: currentEntryBeginTime)
            debugLog("[SMILPlayerManager] Already at beginning, seeking to start of current entry")
        }

        updateNowPlayingInfo()
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.smilPlayerRemoteCommandReceived(command: .play)
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.smilPlayerRemoteCommandReceived(command: .pause)
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.smilPlayerRemoteCommandReceived(command: .skipForward(seconds: 15))
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.smilPlayerRemoteCommandReceived(command: .skipBackward(seconds: 15))
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.delegate?.smilPlayerRemoteCommandReceived(command: .seekTo(position: positionEvent.positionTime))
            }
            return .success
        }

        debugLog("[SMILPlayerManager] Remote command center configured")
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        var info = [String: Any]()

        info[MPMediaItemPropertyTitle] = bookTitle ?? "Silveran Reader"
        info[MPMediaItemPropertyArtist] = currentChapterLabel()
        info[MPMediaItemPropertyAlbumTitle] = bookAuthor ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(audioPlayer?.rate ?? 1.0)

        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func currentChapterLabel() -> String {
        guard currentSectionIndex < bookStructure.count else { return "" }
        return bookStructure[currentSectionIndex].label ?? "Chapter \(currentSectionIndex + 1)"
    }

    // MARK: - Cleanup

    func cleanup() {
        debugLog("[SMILPlayerManager] Cleanup")
        stopUpdateTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        state = .idle

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }
}
