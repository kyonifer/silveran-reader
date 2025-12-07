#if canImport(AVFoundation)
import AVFoundation
import Foundation

public struct AudioPositionSyncData: Sendable {
    public let sectionIndex: Int
    public let entryIndex: Int
    public let currentTime: Double
    public let audioFile: String
    public let href: String
    public let fragment: String

    public init(
        sectionIndex: Int,
        entryIndex: Int,
        currentTime: Double,
        audioFile: String,
        href: String,
        fragment: String
    ) {
        self.sectionIndex = sectionIndex
        self.entryIndex = entryIndex
        self.currentTime = currentTime
        self.audioFile = audioFile
        self.href = href
        self.fragment = fragment
    }
}

@MainActor
public protocol SMILPlayerManagerDelegate: AnyObject {
    func smilPlayerDidAdvanceToEntry(sectionIndex: Int, entryIndex: Int, entry: SMILEntry)
    func smilPlayerDidFinishBook()
    func smilPlayerDidUpdateTime(currentTime: Double, sectionIndex: Int, entryIndex: Int)
    func smilPlayerShouldAdvanceToNextSection(fromSection: Int) -> Bool
}

@MainActor
@Observable
public class SMILPlayerManager: NSObject, AVAudioPlayerDelegate {
    // MARK: - State

    public enum PlayerState: Sendable {
        case idle
        case loading
        case ready
        case playing
        case paused
    }

    public private(set) var state: PlayerState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    private var lastPausedWhilePlayingTime: Date?

    // MARK: - SMIL Tracking

    private var bookStructure: [SectionInfo] = []
    private var currentSectionIndex: Int = 0
    private var currentEntryIndex: Int = 0
    private var currentAudioFile: String = ""
    private var currentEntryBeginTime: Double = 0
    private var currentEntryEndTime: Double = 0
    private var epubPath: URL?

    // MARK: - AVFoundation

    private var audioPlayer: AVAudioPlayer?
    private var updateTimer: Timer?
    private var currentPlaybackRate: Float = 1.0

    // MARK: - Delegate

    public weak var delegate: SMILPlayerManagerDelegate?
    private var lastProgressUpdateTime: Date = .distantPast

    // MARK: - Initialization

    public init(bookStructure: [SectionInfo], epubPath: URL?, initialPlaybackRate: Double = 1.0) {
        self.bookStructure = bookStructure
        self.epubPath = epubPath
        self.currentPlaybackRate = Float(initialPlaybackRate)
        super.init()
        debugLog(
            "[SMILPlayerManager] Initialized with \(bookStructure.count) sections, epubPath: \(epubPath?.path ?? "nil"), rate: \(initialPlaybackRate)"
        )
    }

    // MARK: - Entry Management

    public func setCurrentEntry(
        sectionIndex: Int,
        entryIndex: Int,
        audioFile: String,
        beginTime: Double,
        endTime: Double
    ) async {
        debugLog(
            "[SMILPlayerManager] setCurrentEntry: section=\(sectionIndex), entry=\(entryIndex), file=\(audioFile), begin=\(beginTime), end=\(endTime)"
        )

        let wasRecentlyPlaying: Bool
        if let pauseTime = lastPausedWhilePlayingTime {
            let elapsed = Date().timeIntervalSince(pauseTime)
            wasRecentlyPlaying = elapsed < 0.5
            debugLog(
                "[SMILPlayerManager] Time since pause: \(elapsed)s, wasRecentlyPlaying=\(wasRecentlyPlaying)"
            )
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
    }

    public func seekToFragment(sectionIndex: Int, textId: String) async -> Bool {
        guard sectionIndex >= 0 && sectionIndex < bookStructure.count else {
            debugLog("[SMILPlayerManager] seekToFragment - invalid section: \(sectionIndex)")
            return false
        }

        let section = bookStructure[sectionIndex]
        guard let entryIndex = section.mediaOverlay.firstIndex(where: { $0.textId == textId })
        else {
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

    public func getCurrentEntry() -> SMILEntry? {
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }
        return section.mediaOverlay[currentEntryIndex]
    }

    public func getCurrentPosition() -> (sectionIndex: Int, entryIndex: Int) {
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
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.rate = currentPlaybackRate
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0
            state = .ready
            debugLog(
                "[SMILPlayerManager] Audio loaded from EPUB, duration: \(duration)s, rate: \(currentPlaybackRate)"
            )
        } catch {
            debugLog("[SMILPlayerManager] Failed to load audio from EPUB: \(error)")
            state = .idle
        }
    }

    // MARK: - Playback Control

    public func play() {
        guard let player = audioPlayer else {
            debugLog("[SMILPlayerManager] play() - no audio player")
            return
        }

        debugLog("[SMILPlayerManager] play()")
        player.play()
        state = .playing
        startUpdateTimer()
    }

    public func pause() {
        guard let player = audioPlayer else { return }

        if state == .playing {
            lastPausedWhilePlayingTime = Date()
        }

        debugLog("[SMILPlayerManager] pause()")
        player.pause()
        state = .paused
        stopUpdateTimer()
    }

    public func seek(to time: Double) {
        guard let player = audioPlayer else {
            debugLog("[SMILPlayerManager] seek(to: \(time)) - no audio player")
            return
        }

        debugLog("[SMILPlayerManager] seek(to: \(time)), player.duration=\(player.duration)")
        player.currentTime = time
        currentTime = time
    }

    public func setVolume(_ volume: Double) {
        audioPlayer?.volume = Float(volume)
        debugLog("[SMILPlayerManager] setVolume(\(volume))")
    }

    public func setPlaybackRate(_ rate: Double) {
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

        currentTime = player.currentTime

        if currentTime >= currentEntryEndTime {
            advanceToNextEntry()
        }

        let now = Date()
        if now.timeIntervalSince(lastProgressUpdateTime) >= 0.2 {
            lastProgressUpdateTime = now
            delegate?.smilPlayerDidUpdateTime(
                currentTime: currentTime,
                sectionIndex: currentSectionIndex,
                entryIndex: currentEntryIndex
            )
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            debugLog(
                "[SMILPlayerManager] Audio file finished playing (delegate callback, success=\(flag))"
            )
            advanceToNextEntry()
        }
    }

    // MARK: - Background Sync

    public func getBackgroundSyncData() -> AudioPositionSyncData? {
        guard state == .playing || state == .paused else { return nil }
        guard currentSectionIndex < bookStructure.count else { return nil }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return nil }

        let entry = section.mediaOverlay[currentEntryIndex]

        debugLog(
            "[SMILPlayerManager] getBackgroundSyncData: section=\(currentSectionIndex), entry=\(currentEntryIndex), fragment=\(entry.textId)"
        )

        return AudioPositionSyncData(
            sectionIndex: currentSectionIndex,
            entryIndex: currentEntryIndex,
            currentTime: currentTime,
            audioFile: currentAudioFile,
            href: entry.textHref,
            fragment: entry.textId
        )
    }

    public func reconcilePositionFromPlayer() {
        guard let player = audioPlayer else { return }
        guard currentSectionIndex < bookStructure.count else { return }

        let actualTime = player.currentTime
        currentTime = actualTime

        let section = bookStructure[currentSectionIndex]
        for (index, entry) in section.mediaOverlay.enumerated() {
            if actualTime >= entry.begin && actualTime < entry.end {
                if index != currentEntryIndex {
                    debugLog(
                        "[SMILPlayerManager] Reconciled entry: was \(currentEntryIndex), now \(index)"
                    )
                    currentEntryIndex = index
                    currentEntryBeginTime = entry.begin
                    currentEntryEndTime = entry.end
                }
                return
            }
        }

        debugLog(
            "[SMILPlayerManager] Could not reconcile entry for time \(actualTime) in section \(currentSectionIndex)"
        )
    }

    // MARK: - Entry Navigation

    public func advanceToNextEntry() {
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

            debugLog(
                "[SMILPlayerManager] Advanced to entry \(nextEntryIndex) in section \(currentSectionIndex)"
            )
            delegate?.smilPlayerDidAdvanceToEntry(
                sectionIndex: currentSectionIndex,
                entryIndex: currentEntryIndex,
                entry: nextEntry
            )
        } else {
            if delegate?.smilPlayerShouldAdvanceToNextSection(fromSection: currentSectionIndex)
                == false
            {
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
                    delegate?.smilPlayerDidAdvanceToEntry(
                        sectionIndex: currentSectionIndex,
                        entryIndex: currentEntryIndex,
                        entry: nextEntry
                    )
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
    }

    public func goToPreviousEntry() {
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

            debugLog(
                "[SMILPlayerManager] Went back to entry \(currentEntryIndex) in section \(currentSectionIndex)"
            )
            delegate?.smilPlayerDidAdvanceToEntry(
                sectionIndex: currentSectionIndex,
                entryIndex: currentEntryIndex,
                entry: prevEntry
            )
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

                debugLog(
                    "[SMILPlayerManager] Went back to section \(prevSectionIndex), entry \(currentEntryIndex)"
                )
                delegate?.smilPlayerDidAdvanceToEntry(
                    sectionIndex: currentSectionIndex,
                    entryIndex: currentEntryIndex,
                    entry: lastEntry
                )
            }
        } else {
            seek(to: currentEntryBeginTime)
            debugLog("[SMILPlayerManager] Already at beginning, seeking to start of current entry")
        }
    }

    // MARK: - Cleanup

    public func cleanup() {
        debugLog("[SMILPlayerManager] Cleanup")
        stopUpdateTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        state = .idle
    }
}
#endif
