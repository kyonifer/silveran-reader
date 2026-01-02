#if canImport(AVFoundation)
import AVFoundation
import Foundation

#if os(iOS) || os(watchOS)
import MediaPlayer
#endif

#if os(iOS)
import UIKit
#endif

// MARK: - Audio Position Sync

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

// MARK: - AVPlayer Observer

private class AVPlayerEndObserver: NSObject, @unchecked Sendable {
    private var observer: NSObjectProtocol?

    func observe(_ playerItem: AVPlayerItem) {
        cleanup()
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: nil
        ) { _ in
            debugLog("[SMILPlayerActor] Audio finished playing")
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.handleAudioFinished()
            }
        }
    }

    func cleanup() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
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

    private var player: AVPlayer?
    private let endObserver = AVPlayerEndObserver()
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
    private var isAdvancing: Bool = false

    // MARK: - Observer Pattern

    private var stateObservers: [UUID: @Sendable @MainActor (SMILPlaybackState) -> Void] = [:]
    private var sessionID = UUID()

    // MARK: - iOS/watchOS Audio

    #if os(iOS) || os(watchOS)
    private var audioManager: SMILAudioManager?
    private var nowPlayingUpdateTimer: Timer?
    private var audioSessionObserversConfigured = false
    private var audioSessionInitialized = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    #endif

    #if os(iOS)
    private var coverImage: UIImage?
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

        if self.bookId == bookId && !bookStructure.isEmpty {
            debugLog("[SMILPlayerActor] Same book already loaded, skipping reload")
            sessionID = UUID()
            #if os(iOS) || os(watchOS)
            setupAudioSession()
            configureAudioSessionObservers()
            #endif
            await notifyStateChange()
            return
        }

        sessionID = UUID()
        clearBookState()

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

        #if os(iOS) || os(watchOS)
        setupAudioSession()
        configureAudioSessionObservers()
        await setupAudioManager()
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

    public func getLoadedBookTitle() -> String? {
        return bookTitle
    }

    // MARK: - Cover Image (iOS)

    #if os(iOS)
    public func setCoverImage(_ image: UIImage?) async {
        coverImage = image
        let manager = audioManager
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

        #if os(iOS) || os(watchOS)
        ensureAudioSessionActive()
        #endif

        player.rate = Float(playbackRate)
        isPlaying = true
        startUpdateTimer()

        #if os(iOS) || os(watchOS)
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

        #if os(iOS) || os(watchOS)
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
        guard let entryIndex = section.mediaOverlay.firstIndex(where: { $0.textId == textId })
        else {
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

    public func seekToTotalProgression(_ progression: Double) async -> Bool {
        guard let (sectionIndex, entryIndex, entry) = findEntryByTotalProgression(progression)
        else {
            return false
        }

        await setCurrentEntry(
            sectionIndex: sectionIndex,
            entryIndex: entryIndex,
            audioFile: entry.audioFile,
            beginTime: entry.begin,
            endTime: entry.end
        )
        return true
    }

    public func findPositionByTotalProgression(_ progression: Double) -> (
        sectionIndex: Int, textId: String
    )? {
        guard let (sectionIndex, _, entry) = findEntryByTotalProgression(progression) else {
            return nil
        }
        return (sectionIndex, entry.textId)
    }

    private func findEntryByTotalProgression(_ progression: Double) -> (
        sectionIndex: Int, entryIndex: Int, entry: SMILEntry
    )? {
        guard !bookStructure.isEmpty else { return nil }

        var totalDuration: Double = 0
        for section in bookStructure.reversed() {
            if let lastEntry = section.mediaOverlay.last {
                totalDuration = lastEntry.cumSumAtEnd
                break
            }
        }

        guard totalDuration > 0 else { return nil }

        let targetTime = progression * totalDuration
        debugLog(
            "[SMILPlayerActor] findEntryByTotalProgression: \(progression) -> targetTime \(targetTime)s of \(totalDuration)s"
        )

        for (sectionIndex, section) in bookStructure.enumerated() {
            for (entryIndex, entry) in section.mediaOverlay.enumerated() {
                if entry.cumSumAtEnd >= targetTime {
                    return (sectionIndex, entryIndex, entry)
                }
            }
        }

        return nil
    }

    public func skipForward(seconds: Double = 15) async {
        guard let player = player else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let newTime = min(player.currentTime().seconds + seconds, duration)
        await player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1000))
        reconcileEntryFromTime(newTime)
        await notifyStateChange()
    }

    public func skipBackward(seconds: Double = 15) async {
        guard let player = player else { return }
        let newTime = max(player.currentTime().seconds - seconds, 0)
        await player.seek(to: CMTime(seconds: newTime, preferredTimescale: 1000))
        reconcileEntryFromTime(newTime)
        await notifyStateChange()
    }

    // MARK: - Settings

    public func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        if isPlaying {
            player?.rate = Float(rate)
        }
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
            currentTime: player?.currentTime().seconds ?? 0,
            audioFile: currentAudioFile,
            href: entry.textHref,
            fragment: entry.textId
        )
    }

    public func reconcilePositionFromPlayer() {
        guard let player = player else { return }
        reconcileEntryFromTime(player.currentTime().seconds)
    }

    // MARK: - Cleanup

    private func clearBookState() {
        debugLog("[SMILPlayerActor] Clearing book state")
        stopUpdateTimer()
        endObserver.cleanup()
        player?.pause()
        player = nil

        if let tempFile = tempAudioFileURL {
            try? FileManager.default.removeItem(at: tempFile)
            tempAudioFileURL = nil
        }

        bookStructure = []
        epubPath = nil
        bookId = nil
        bookTitle = nil
        bookAuthor = nil
        currentSectionIndex = 0
        currentEntryIndex = 0
        currentAudioFile = ""
        isPlaying = false

        #if os(iOS) || os(watchOS)
        stopNowPlayingUpdateTimer()
        #endif
    }

    public func cleanup(expectedSessionID: UUID? = nil) async {
        if let expectedSessionID, expectedSessionID != sessionID {
            debugLog("[SMILPlayerActor] Cleanup skipped due to session mismatch")
            return
        }

        debugLog("[SMILPlayerActor] Cleanup")
        clearBookState()

        #if os(iOS)
        removeAudioSessionObservers()
        await cleanupAudioManager()
        audioSessionInitialized = false
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            debugLog("[SMILPlayerActor] Failed to deactivate audio session: \(error)")
        }
        coverImage = nil
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
            let duration = player.currentItem?.duration.seconds ?? 0
            debugLog(
                "[SMILPlayerActor] setCurrentEntry: BEFORE seek - currentTime=\(player.currentTime().seconds), duration=\(duration), target=\(beginTime)"
            )
            await player.seek(to: CMTime(seconds: beginTime, preferredTimescale: 1000))
            debugLog(
                "[SMILPlayerActor] setCurrentEntry: AFTER seek - currentTime=\(player.currentTime().seconds)"
            )

            if wasRecentlyPlaying {
                lastPausedWhilePlayingTime = nil
                player.rate = Float(playbackRate)
                isPlaying = true
                startUpdateTimer()
                #if os(iOS) || os(watchOS)
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
            if let nextSection = bookStructure.first(where: {
                $0.index > currentSectionIndex && !$0.mediaOverlay.isEmpty
            }) {
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
        if let player = player {
            await player.seek(to: CMTime(seconds: currentEntryBeginTime, preferredTimescale: 1000))
        }
    }

    private var tempAudioFileURL: URL?

    private func loadAudioFile(_ relativeAudioFile: String) async {
        guard let epubPath = epubPath else {
            debugLog("[SMILPlayerActor] No EPUB path for audio loading")
            return
        }

        debugLog("[SMILPlayerActor] Loading audio file: \(relativeAudioFile)")

        do {
            // Clean up previous temp file
            if let oldTemp = tempAudioFileURL {
                try? FileManager.default.removeItem(at: oldTemp)
            }

            let tempDir = FileManager.default.temporaryDirectory
            let ext = (relativeAudioFile as NSString).pathExtension
            let tempFile = tempDir.appendingPathComponent("smil_audio_\(UUID().uuidString).\(ext)")
            tempAudioFileURL = tempFile

            try await FilesystemActor.shared.extractAudioToFile(
                from: epubPath,
                audioPath: relativeAudioFile,
                destination: tempFile
            )

            debugLog("[SMILPlayerActor] Extracted to temp file: \(tempFile.path)")

            let playerItem = AVPlayerItem(url: tempFile)
            let newPlayer = AVPlayer(playerItem: playerItem)
            newPlayer.rate = 0  // Start paused
            newPlayer.volume = Float(volume)
            endObserver.observe(playerItem)
            self.player = newPlayer

            let duration = playerItem.duration.seconds
            debugLog("[SMILPlayerActor] Audio loaded, duration: \(duration.isNaN ? 0 : duration)s")
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
        guard let player = player else { return }

        let currentTime = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        let tolerance = 0.02
        let playerIsPlaying = player.rate > 0

        debugLog(
            "[SMILPlayerActor] timerFired: currentTime=\(currentTime), duration=\(duration), entryEnd=\(currentEntryEndTime), isPlaying=\(playerIsPlaying)"
        )

        let reachedEntryEnd = currentTime >= currentEntryEndTime - tolerance
        let reachedFileEnd = duration > 0 && currentTime >= duration - tolerance

        if isPlaying && (reachedEntryEnd || reachedFileEnd) {
            await advanceToNextEntry()
        } else if !isPlaying && reachedFileEnd && !playerIsPlaying {
            debugLog("[SMILPlayerActor] Audio file ended naturally, advancing...")
            isPlaying = true
            await advanceToNextEntry()
        }

        let now = Date()
        if now.timeIntervalSince(lastProgressNotifyTime) >= 0.2 {
            lastProgressNotifyTime = now
            await notifyStateChange()
        }
    }

    func handleAudioFinished() async {
        guard isPlaying else {
            debugLog("[SMILPlayerActor] handleAudioFinished called but not playing, ignoring")
            return
        }

        debugLog("[SMILPlayerActor] handleAudioFinished - advancing to next entry/chapter")
        await advanceToNextEntry()
    }

    // MARK: - Private: Entry Navigation

    private func advanceToNextEntry() async {
        guard !isAdvancing else {
            debugLog("[SMILPlayerActor] advanceToNextEntry already in progress, skipping")
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }

        guard currentSectionIndex < bookStructure.count else {
            debugLog(
                "[SMILPlayerActor] End of book - currentSectionIndex \(currentSectionIndex) >= count \(bookStructure.count)"
            )
            await pause()
            return
        }

        let section = bookStructure[currentSectionIndex]
        let nextEntryIndex = currentEntryIndex + 1

        debugLog(
            "[SMILPlayerActor] advanceToNextEntry: section=\(currentSectionIndex), nextEntry=\(nextEntryIndex), overlayCount=\(section.mediaOverlay.count)"
        )

        if nextEntryIndex < section.mediaOverlay.count {
            let nextEntry = section.mediaOverlay[nextEntryIndex]
            currentEntryIndex = nextEntryIndex
            currentEntryBeginTime = nextEntry.begin
            currentEntryEndTime = nextEntry.end

            if nextEntry.audioFile != currentAudioFile {
                currentAudioFile = nextEntry.audioFile
                await loadAudioFile(nextEntry.audioFile)
                if let player = player {
                    await player.seek(
                        to: CMTime(seconds: nextEntry.begin, preferredTimescale: 1000)
                    )
                    if isPlaying {
                        player.rate = Float(playbackRate)
                    }
                }
            }

            debugLog(
                "[SMILPlayerActor] Advanced to entry \(nextEntryIndex) in section \(currentSectionIndex)"
            )
            await notifyStateChange()
        } else {
            let nextSectionIndex = currentSectionIndex + 1
            debugLog(
                "[SMILPlayerActor] Section \(currentSectionIndex) complete, looking for next section >= \(nextSectionIndex)"
            )
            if let nextSection = bookStructure.first(where: {
                $0.index >= nextSectionIndex && !$0.mediaOverlay.isEmpty
            }) {
                let nextEntry = nextSection.mediaOverlay[0]
                currentSectionIndex = nextSection.index
                currentEntryIndex = 0
                currentEntryBeginTime = nextEntry.begin
                currentEntryEndTime = nextEntry.end
                currentAudioFile = nextEntry.audioFile

                await loadAudioFile(nextEntry.audioFile)
                if let player = player {
                    await player.seek(
                        to: CMTime(seconds: nextEntry.begin, preferredTimescale: 1000)
                    )
                    if isPlaying {
                        player.rate = Float(playbackRate)
                    }
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
            if entry.audioFile == currentAudioFile && time >= entry.begin && time < entry.end {
                if index != currentEntryIndex {
                    currentEntryIndex = index
                    currentEntryBeginTime = entry.begin
                    currentEntryEndTime = entry.end
                }
                return
            }
        }

        debugLog(
            "[SMILPlayerActor] reconcileEntryFromTime: no matching entry for time \(time) in audioFile \(currentAudioFile)"
        )
    }

    // MARK: - Private: State Building

    private func buildCurrentState() -> SMILPlaybackState? {
        guard !bookStructure.isEmpty else { return nil }

        let currentTime = player?.currentTime().seconds ?? 0
        let duration = player?.currentItem?.duration.seconds ?? 0

        var chapterLabel: String? = nil
        var chapterElapsed: Double = 0
        var chapterTotal: Double = 0
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
            chapterLabel = section.label

            if !section.mediaOverlay.isEmpty {
                let chapterStartCumSum: Double
                if let prevSection = bookStructure.prefix(currentSectionIndex).last(where: {
                    !$0.mediaOverlay.isEmpty
                }),
                    let prevLastEntry = prevSection.mediaOverlay.last
                {
                    chapterStartCumSum = prevLastEntry.cumSumAtEnd
                } else {
                    chapterStartCumSum = 0
                }

                if let lastEntry = section.mediaOverlay.last {
                    chapterTotal = lastEntry.cumSumAtEnd - chapterStartCumSum
                }

                if currentEntryIndex < section.mediaOverlay.count {
                    let entry = section.mediaOverlay[currentEntryIndex]
                    let entryCumSum =
                        currentEntryIndex > 0
                        ? section.mediaOverlay[currentEntryIndex - 1].cumSumAtEnd
                        : chapterStartCumSum
                    let timeInEntry = currentTime - entry.begin
                    bookElapsed = entryCumSum + max(0, timeInEntry)
                    chapterElapsed = bookElapsed - chapterStartCumSum
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

        #if os(iOS) || os(watchOS)
        updateNowPlayingInfo()
        #endif
        debugLog("[SMILPlayerActor] notifyStateChange: \(stateObservers.count) observers")
        for observer in stateObservers.values {
            await observer(state)
        }
    }

    // MARK: - iOS/watchOS Audio Session

    #if os(iOS) || os(watchOS)
    private func setupAudioSession() {
        if audioSessionInitialized {
            debugLog("[SMILPlayerActor] Audio session already initialized, skipping setup")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            audioSessionInitialized = true
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

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self = self else { return }
            self.handleAudioSessionInterruption(notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
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
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        audioSessionObserversConfigured = false
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
    // MARK: - Audio Manager

    private func setupAudioManager() async {
        let title = bookTitle
        let author = bookAuthor
        #if os(iOS)
        let cover = coverImage
        #endif

        if let existingManager = audioManager {
            await MainActor.run {
                existingManager.bookTitle = title
                existingManager.bookAuthor = author
                #if os(iOS)
                existingManager.coverImage = cover
                #endif
            }
            debugLog("[SMILPlayerActor] AudioManager updated with new book info")
            return
        }

        let manager = await MainActor.run {
            let m = SMILAudioManager()
            m.bookTitle = title
            m.bookAuthor = author
            #if os(iOS)
            m.coverImage = cover
            #endif
            return m
        }
        self.audioManager = manager
        debugLog("[SMILPlayerActor] AudioManager created")
    }

    private func cleanupAudioManager() async {
        let manager = audioManager
        await MainActor.run {
            manager?.cleanup()
        }
        audioManager = nil
    }

    private func updateNowPlayingInfo() {
        guard !bookStructure.isEmpty else {
            let manager = audioManager
            Task { @MainActor in
                manager?.clearNowPlayingInfo()
            }
            return
        }

        let state = buildCurrentState()
        let manager = audioManager
        debugLog(
            "[SMILPlayerActor] updateNowPlayingInfo: isPlaying=\(state?.isPlaying ?? false), hasManager=\(manager != nil)"
        )

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
    #endif
}

// MARK: - Audio Manager Helper

#if os(iOS) || os(watchOS)
@MainActor
class SMILAudioManager {
    var bookTitle: String?
    var bookAuthor: String?

    #if os(iOS)
    var coverImage: UIImage? {
        didSet {
            cachedArtwork = coverImage.map { createArtwork(from: $0) }
        }
    }
    private var cachedArtwork: MPMediaItemArtwork?
    #endif

    init() {
        debugLog("[SMILAudioManager] Initializing")
        setupRemoteCommandCenter()
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManager] Remote play command")
                try? await SMILPlayerActor.shared.play()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManager] Remote pause command")
                await SMILPlayerActor.shared.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManager] Remote toggle play/pause command")
                try? await SMILPlayerActor.shared.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManager] Remote skip forward command")
                await SMILPlayerActor.shared.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @SMILPlayerActor in
                debugLog("[SMILAudioManager] Remote skip backward command")
                await SMILPlayerActor.shared.skipBackward()
            }
            return .success
        }

        debugLog("[SMILAudioManager] Remote commands configured")
    }

    func updateNowPlayingInfo(
        currentTime: Double,
        duration: Double,
        chapterLabel: String,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        let rate = isPlaying ? playbackRate : 0.0
        debugLog("[SMILAudioManager] updateNowPlayingInfo: isPlaying=\(isPlaying), rate=\(rate)")

        var info = [String: Any]()

        info[MPMediaItemPropertyTitle] = bookTitle ?? "Silveran Reader"
        info[MPMediaItemPropertyArtist] = chapterLabel
        info[MPMediaItemPropertyAlbumTitle] = bookAuthor ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate

        #if os(iOS)
        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        #endif

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func cleanup() {
        debugLog("[SMILAudioManager] Cleanup")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
    }

    #if os(iOS)
    nonisolated private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
    #endif
}
#endif
#endif
