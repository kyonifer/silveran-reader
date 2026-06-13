import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct AudiobookPlayerView: View {
    private let bookData: PlayerBookData?
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var chapterProgress: Double = 0.0
    @State private var isPlaying = false
    @State private var playbackRate: Double = 1.0
    @State private var volume: Double = 1.0
    @State private var sleepTimerActive = false
    @State private var sleepTimerRemaining: TimeInterval? = nil
    @State private var sleepTimerType: SleepTimerType? = nil
    @State private var sleepTimer: Timer? = nil
    @State private var settingsInitialized = false

    @State private var metadata: AudiobookMetadata?
    @State private var currentChapterTitle: String = "Loading..."
    @State private var chapterDuration: TimeInterval = 0
    @State private var totalRemaining: TimeInterval = 0
    @State private var chapters: [ChapterItem] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var stateObserverID: UUID?
    @State private var progressTimer: Timer?
    @State private var syncTimer: Timer?
    @State private var lastSyncedProgress: Double = 0.0
    @State private var progressMessage: PlaybackProgressUpdateMessage?
    @State private var lastRestartTime: Date?

    @State private var showServerPositionDialog = false
    @State private var pendingServerPosition: IncomingServerPosition? = nil
    @State private var incomingPositionObserverId: UUID? = nil
    @State private var positionObserverRegistrationTask: Task<Void, Never>? = nil

    public init(bookData: PlayerBookData?, onClose: (() -> Void)? = nil) {
        self.bookData = bookData
        self.onClose = onClose
    }

    public var body: some View {
        readingSidebarView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
            #endif
            .alert("Audiobook Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
            .alert(
                "Server Has Newer Position",
                isPresented: $showServerPositionDialog,
            ) {
                Button("Go to New Position") {
                    acceptServerPosition()
                }
                Button("Stay Here", role: .cancel) {
                    declineServerPosition()
                }
            } message: {
                Text(serverPositionDescription)
            }
            .onAppear {
                #if os(iOS)
                CarPlayCoordinator.shared.isPlayerViewActive = true
                debugLog(
                    "[LastOpenBookStore] AudiobookPlayerView onAppear scenePhase=\(scenePhase) bookId=\(bookData?.metadata.uuid ?? "nil")"
                )
                if let bookData {
                    Task {
                        await LastOpenBookStore.save(bookData: bookData)
                    }
                }
                #endif

                if !settingsInitialized {
                    Task { @MainActor in
                        let config = await SettingsActor.shared.config
                        playbackRate = config.playback.defaultPlaybackSpeed
                        volume = config.playback.defaultVolume
                        settingsInitialized = true
                    }
                }

                Task { @MainActor in
                    await loadAudiobook()
                }
            }
            .onDisappear {
                #if os(iOS)
                debugLog(
                    "[LastOpenBookStore] AudiobookPlayerView onDisappear scenePhase=\(scenePhase) bookId=\(bookData?.metadata.uuid ?? "nil")"
                )
                if scenePhase == .active {
                    CarPlayCoordinator.shared.isPlayerViewActive = false
                }
                guard scenePhase == .active else {
                    debugLog(
                        "[AudiobookPlayerView] Background disappear - preserving audio playback"
                    )
                    return
                }
                #endif

                progressTimer?.invalidate()
                progressTimer = nil
                syncTimer?.invalidate()
                syncTimer = nil
                sleepTimer?.invalidate()
                sleepTimer = nil

                positionObserverRegistrationTask?.cancel()

                Task {
                    await syncProgressToServer(reason: .userClosedBook)

                    if let observerID = stateObserverID {
                        await AudiobookActor.shared.removeStateObserver(id: observerID)
                    }
                    await positionObserverRegistrationTask?.value
                    if let observerId = incomingPositionObserverId {
                        await ProgressSyncActor.shared.removeIncomingPositionObserver(
                            id: observerId
                        )
                    }
                    debugLog("[AudiobookPlayerView] onDisappear: calling AudiobookActor.cleanup()")
                    await AudiobookActor.shared.cleanup()
                }
            }
            .onChange(of: playbackRate) { _, newValue in
                if settingsInitialized {
                    Task {
                        await AudiobookActor.shared.setPlaybackRate(newValue)
                        do {
                            try await SettingsActor.shared.updateConfig(
                                defaultPlaybackSpeed: newValue
                            )
                        } catch {
                            debugLog(
                                "[AudiobookPlayerView] Failed to auto-save playback rate: \(error)"
                            )
                        }
                    }
                }
            }
            .onChange(of: volume) { _, newValue in
                if settingsInitialized {
                    Task {
                        await AudiobookActor.shared.setVolume(newValue)
                        do {
                            try await SettingsActor.shared.updateConfig(defaultVolume: newValue)
                        } catch {
                            debugLog("[AudiobookPlayerView] Failed to auto-save volume: \(error)")
                        }
                    }
                }
            }
            #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closeBook()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        #endif
    }

    #if os(iOS)
    private func closeBook() {
        if let bookData {
            LastOpenBookStore.clearIfMatching(
                bookId: bookData.metadata.uuid,
                category: bookData.category,
            )
        }
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
    #endif

    private var readingSidebarView: some View {
        let bookTitle = bookData?.metadata.title ?? "Unknown Book"
        let bookAuthor = bookData?.metadata.authors?.first?.name ?? "Unknown Author"

        return ReadingSidebarView(
            bookData: bookData,
            model: .init(
                title: bookTitle,
                author: bookAuthor,
                chapterTitle: currentChapterTitle,
                coverArt: bookData?.coverArt,
                ebookCoverArt: bookData?.ebookCoverArt,
                chapterDuration: chapterDuration,
                totalRemaining: totalRemaining,
                playbackRate: playbackRate,
                volume: volume,
                isPlaying: isPlaying,
                sleepTimerActive: sleepTimerActive,
                sleepTimerRemaining: sleepTimerRemaining,
                sleepTimerType: sleepTimerType,
            ),
            mode: .audiobook,
            chapterProgress: $chapterProgress,
            chapters: chapters,
            progressData: progressMessage.map { msg in
                ProgressData(
                    chapterId: msg.chapterId,
                    chapterLabel: msg.chapterLabel,
                    chapterCurrentPage: msg.chapterCurrentPage,
                    chapterTotalPages: msg.chapterTotalPages,
                    chapterCurrentSecondsAudio: msg.chapterCurrentSecondsAudio,
                    chapterTotalSecondsAudio: msg.chapterTotalSecondsAudio,
                    bookCurrentSecondsAudio: msg.bookCurrentSecondsAudio,
                    bookTotalSecondsAudio: msg.bookTotalSecondsAudio,
                    bookCurrentFraction: msg.bookCurrentFraction,
                )
            },
            onChapterSelected: { chapter in
                Task {
                    await AudiobookActor.shared.seekToChapter(href: chapter.href)
                }
            },
            onPrevChapter: {
                handlePrevChapter()
            },
            onSkipBackward: {
                Task {
                    await AudiobookActor.shared.skipBackward()
                }
            },
            onPlayPause: {
                Task {
                    do {
                        try await AudiobookActor.shared.togglePlayPause()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            },
            onSkipForward: {
                Task {
                    await AudiobookActor.shared.skipForward()
                }
            },
            onNextChapter: {
                handleNextChapter()
            },
            onPlaybackRateChange: { rate in
                playbackRate = rate
            },
            onVolumeChange: { newVolume in
                volume = newVolume
            },
            onSleepTimerStart: { duration, type in
                startSleepTimer(duration: duration, type: type)
            },
            onSleepTimerCancel: {
                cancelSleepTimer()
            },
            onProgressSeek: { fraction in
                Task {
                    if let metadata = metadata,
                        let chapterIndex = await AudiobookActor.shared.getCurrentChapterIndex(),
                        chapterIndex < metadata.chapters.count
                    {
                        let chapter = metadata.chapters[chapterIndex]
                        let targetTime = chapter.startTime + (chapter.duration * fraction)
                        await AudiobookActor.shared.seek(to: targetTime)
                    }
                }
            },
            seekWhileDragging: false,
        )
    }

    private func loadAudiobook() async {
        guard let bookData = bookData, let mediaURL = bookData.localMediaPath else {
            errorMessage = "No audiobook file available"
            isLoading = false
            return
        }

        if await SMILPlayerActor.shared.activeAudioPlayer == .smil {
            await SMILPlayerActor.shared.cleanup()
            debugLog("[AudiobookPlayerView] Cleaned up SMILPlayerActor before loading audiobook")
        }

        do {
            let loadedMetadata = try await AudiobookActor.shared.validateAndLoadAudiobook(
                url: mediaURL
            )
            metadata = loadedMetadata

            chapters = loadedMetadata.chapters.map { chapter in
                ChapterItem(
                    id: chapter.id,
                    label: chapter.title,
                    href: chapter.id,
                    level: 0,
                )
            }

            totalRemaining = loadedMetadata.totalDuration

            try await AudiobookActor.shared.preparePlayer()

            await AudiobookActor.shared.setPlaybackRate(playbackRate)
            await AudiobookActor.shared.setVolume(volume)

            if let psaProgress = await ProgressSyncActor.shared.getBookProgress(
                for: bookData.metadata.uuid
            ),
                let totalProgression = psaProgress.locator?.locations?.totalProgression
            {
                debugLog(
                    "[AudiobookPlayerView] Got position from PSA (source: \(psaProgress.source))"
                )
                await AudiobookActor.shared.seekToTotalProgressFraction(totalProgression)
                lastSyncedProgress = totalProgression
            }

            let observerID = await AudiobookActor.shared.addStateObserver { state in
                Task { @MainActor in
                    await MainActor.run {
                        let wasPlaying = self.isPlaying
                        self.isPlaying = state.isPlaying
                        self.updateChapterInfo(for: state)

                        if wasPlaying && !state.isPlaying {
                            debugLog("[AudiobookPlayerView] Playback stopped - syncing progress")
                            Task {
                                await self.syncProgressToServer(reason: .userPausedPlayback)
                            }
                        }
                    }
                }
            }
            stateObserverID = observerID

            startProgressTimer()
            startSyncTimer()

            registerIncomingPositionObserver(bookId: bookData.metadata.uuid)

            isLoading = false
        } catch let error as AudiobookError {
            errorMessage = error.errorDescription
            isLoading = false
        } catch {
            errorMessage = "Failed to load audiobook: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func updateChapterInfo(for state: AudiobookPlaybackState) {
        guard let metadata = metadata else { return }

        let chapterIndex = state.currentChapterIndex
        let currentTime = state.currentTime
        let totalDuration = state.duration

        if let index = chapterIndex, index < metadata.chapters.count {
            let chapter = metadata.chapters[index]
            currentChapterTitle = chapter.title
            chapterDuration = chapter.duration

            let timeInChapter = currentTime - chapter.startTime
            chapterProgress = chapter.duration > 0 ? timeInChapter / chapter.duration : 0

            progressMessage = PlaybackProgressUpdateMessage(
                chapterId: chapter.id,
                chapterLabel: chapter.title,
                chapterCurrentPage: nil,
                chapterTotalPages: nil,
                chapterCurrentSecondsAudio: timeInChapter,
                chapterTotalSecondsAudio: chapter.duration,
                bookCurrentSecondsAudio: currentTime,
                bookTotalSecondsAudio: totalDuration,
                bookCurrentFraction: totalDuration > 0 ? currentTime / totalDuration : 0,
            )
        } else {
            currentChapterTitle = "Unknown Chapter"
            chapterDuration = 0
            chapterProgress = 0

            progressMessage = PlaybackProgressUpdateMessage(
                chapterLabel: nil,
                chapterCurrentPage: nil,
                chapterTotalPages: nil,
                chapterCurrentSecondsAudio: nil,
                chapterTotalSecondsAudio: nil,
                bookCurrentSecondsAudio: currentTime,
                bookTotalSecondsAudio: totalDuration,
                bookCurrentFraction: totalDuration > 0 ? currentTime / totalDuration : 0,
            )
        }

        totalRemaining = max(0, totalDuration - currentTime)

        if let index = chapterIndex, index < metadata.chapters.count {
            let chapter = metadata.chapters[index]
            let timeInChapter = currentTime - chapter.startTime
            checkChapterEndForSleepTimer(elapsed: timeInChapter, total: chapter.duration)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()

        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if let state = await AudiobookActor.shared.getCurrentState() {
                    await MainActor.run {
                        self.updateChapterInfo(for: state)
                    }
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()

        let timer = Timer(timeInterval: 60.0, repeats: true) { _ in
            Task { @MainActor in
                await self.syncProgressToServer(reason: .periodicDuringActivePlayback)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func handlePrevChapter() {
        guard let metadata = metadata else {
            debugLog("[AudiobookPlayerView] Cannot navigate - no metadata")
            return
        }

        Task {
            guard let currentIndex = await AudiobookActor.shared.getCurrentChapterIndex() else {
                debugLog("[AudiobookPlayerView] Cannot navigate - no current chapter")
                return
            }

            let currentChapter = metadata.chapters[currentIndex]
            let currentProgress = chapterProgress
            let now = Date()

            let justRestarted =
                if let lastRestart = lastRestartTime {
                    now.timeIntervalSince(lastRestart) < 2.0
                } else {
                    false
                }

            if currentProgress > 0.01 && !justRestarted {
                debugLog(
                    "[AudiobookPlayerView] Restarting current chapter: \(currentChapter.title) (was at \(Int(currentProgress * 100))%)"
                )
                await AudiobookActor.shared.seekToChapter(href: currentChapter.id)
                lastRestartTime = now
            } else if currentIndex > 0 {
                let prevChapter = metadata.chapters[currentIndex - 1]
                debugLog(
                    "[AudiobookPlayerView] Navigating to previous chapter: \(prevChapter.title)"
                )
                await AudiobookActor.shared.seekToChapter(href: prevChapter.id)
                lastRestartTime = nil
            } else {
                debugLog("[AudiobookPlayerView] Already at beginning of first chapter")
                await AudiobookActor.shared.seekToChapter(href: currentChapter.id)
                lastRestartTime = now
            }
        }
    }

    private func handleNextChapter() {
        guard let metadata = metadata else {
            debugLog("[AudiobookPlayerView] Cannot navigate - no metadata")
            return
        }

        Task {
            guard let currentIndex = await AudiobookActor.shared.getCurrentChapterIndex() else {
                debugLog("[AudiobookPlayerView] Cannot navigate - no current chapter")
                return
            }

            guard currentIndex < metadata.chapters.count - 1 else {
                debugLog("[AudiobookPlayerView] Cannot go to next chapter - at last chapter")
                return
            }

            let nextChapter = metadata.chapters[currentIndex + 1]
            debugLog("[AudiobookPlayerView] Navigating to next chapter: \(nextChapter.title)")
            await AudiobookActor.shared.seekToChapter(href: nextChapter.id)
        }
    }

    /// Sync audiobook progress to server via ProgressSyncActor
    private func syncProgressToServer(reason: SyncReason) async {
        guard let bookId = bookData?.metadata.uuid else {
            return
        }

        guard let state = await AudiobookActor.shared.getCurrentState(),
            let audiobookMeta = metadata
        else {
            return
        }

        let currentProgress = await AudiobookActor.shared.getTotalProgressFraction()

        guard abs(currentProgress - lastSyncedProgress) > 0.001 else {
            return
        }

        let chapterIndex = state.currentChapterIndex ?? 0
        let chapter =
            audiobookMeta.chapters.indices.contains(chapterIndex)
            ? audiobookMeta.chapters[chapterIndex]
            : nil

        let chapterProgression: Double =
            if let ch = chapter, ch.duration > 0 {
                (state.currentTime - ch.startTime) / ch.duration
            } else {
                0.0
            }

        let audioHref = state.currentTrackHref ?? "audiobook"
        let audioType = state.currentTrackType ?? "audio/mp4"
        let timeOffset = state.currentTrackTime

        let locator = BookLocator(
            href: audioHref,
            type: audioType,
            title: chapter?.title,
            locations: BookLocator.Locations(
                fragments: ["t=\(timeOffset)"],
                progression: chapterProgression,
                position: nil,
                totalProgression: currentProgress,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )

        debugLog(
            "[AudiobookPlayerView] Syncing progress (reason: \(reason.rawValue)) - href: \(audioHref), type: \(audioType), t=\(String(format: "%.1f", timeOffset))s, chapterProg: \(String(format: "%.1f%%", chapterProgression * 100)), totalProg: \(String(format: "%.1f%%", currentProgress * 100))"
        )

        let timestamp = floor(Date().timeIntervalSince1970 * 1000)
        let chapterTitle = chapter?.title ?? "Chapter \(chapterIndex + 1)"
        let locationDescription = "\(chapterTitle), \(Int(chapterProgression * 100))%"

        let result = await ProgressSyncActor.shared.syncProgress(
            bookId: bookId,
            sourceID: bookData?.metadata.sourceID,
            locator: locator,
            timestamp: timestamp,
            reason: reason,
            sourceIdentifier: "Audiobook Player",
            locationDescription: locationDescription,
        )

        switch result {
            case .success:
                debugLog("[AudiobookPlayerView] Sync result: SUCCESS")
                lastSyncedProgress = currentProgress
            case .queued:
                debugLog("[AudiobookPlayerView] Sync result: QUEUED (offline)")
                lastSyncedProgress = currentProgress
            case .failed:
                debugLog("[AudiobookPlayerView] Sync result: FAILED (conflict or error)")
        }
    }

    // MARK: - Incoming Server Position Handling

    private var serverPositionDescription: String {
        guard let position = pendingServerPosition else {
            return "Another device has synced a more recent reading position."
        }
        let locator = position.locator
        var details: [String] = []
        if let title = locator.title {
            details.append(title)
        }
        if let prog = locator.locations?.totalProgression {
            details.append("\(Int(prog * 100))%")
        }
        let locationStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return
            "Another device has synced a more recent reading position\(locationStr). Would you like to go to that location?"
    }

    private func acceptServerPosition() {
        guard let position = pendingServerPosition else { return }
        Task {
            await navigateToServerPosition(position.locator)
        }
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    private func declineServerPosition() {
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    @MainActor
    private func navigateToServerPosition(_ locator: BookLocator) async {
        let isAudioLocator = locator.type.contains("audio")

        if let totalProgression = locator.locations?.totalProgression {
            debugLog(
                "[AudiobookPlayerView] Navigating to server position: totalProgression=\(totalProgression) (isAudioLocator=\(isAudioLocator))"
            )
            await AudiobookActor.shared.seekToTotalProgressFraction(totalProgression)
            lastSyncedProgress = totalProgression
        } else {
            debugLog("[AudiobookPlayerView] Server position has no totalProgression, cannot seek")
        }
    }

    private func registerIncomingPositionObserver(bookId: String) {
        positionObserverRegistrationTask = Task {
            let observerId = await ProgressSyncActor.shared.addIncomingPositionObserver(
                for: bookId
            ) { [self] position in
                Task { @MainActor in
                    let config = await SettingsActor.shared.config
                    if config.sync.autoSyncToNewerServerPosition {
                        await navigateToServerPosition(position.locator)
                    } else {
                        pendingServerPosition = position
                        showServerPositionDialog = true
                    }
                }
            }

            guard !Task.isCancelled else {
                await ProgressSyncActor.shared.removeIncomingPositionObserver(id: observerId)
                return
            }

            await MainActor.run {
                incomingPositionObserverId = observerId
            }
            debugLog("[AudiobookPlayerView] Registered incoming position observer for \(bookId)")
        }
    }

    // MARK: - Sleep Timer

    private func startSleepTimer(duration: TimeInterval?, type: SleepTimerType) {
        cancelSleepTimer()

        sleepTimerType = type

        if type == .endOfChapter {
            debugLog("[AudiobookPlayerView] Sleep timer: will pause at end of current chapter")
            sleepTimerActive = true
            sleepTimerRemaining = nil
        } else if let duration = duration {
            debugLog("[AudiobookPlayerView] Sleep timer: starting \(Int(duration))s countdown")
            sleepTimerActive = true
            sleepTimerRemaining = duration

            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    updateSleepTimer()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
        }
    }

    private func cancelSleepTimer() {
        debugLog("[AudiobookPlayerView] Sleep timer cancelled")
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerActive = false
        sleepTimerRemaining = nil
        sleepTimerType = nil
    }

    private func updateSleepTimer() {
        guard sleepTimerActive, isPlaying else { return }

        if sleepTimerType == .endOfChapter {
            return
        }

        guard var remaining = sleepTimerRemaining else {
            cancelSleepTimer()
            return
        }

        remaining -= 1.0
        sleepTimerRemaining = remaining

        if remaining <= 0 {
            debugLog("[AudiobookPlayerView] Sleep timer expired - pausing playback")
            cancelSleepTimer()
            Task {
                await AudiobookActor.shared.pause()
            }
        }
    }

    private func checkChapterEndForSleepTimer(elapsed: TimeInterval, total: TimeInterval) {
        guard sleepTimerActive,
            sleepTimerType == .endOfChapter,
            isPlaying,
            total > 0
        else { return }

        if elapsed >= total - 0.5 {
            debugLog("[AudiobookPlayerView] End of chapter reached - sleep timer pausing playback")
            cancelSleepTimer()
            Task {
                await AudiobookActor.shared.pause()
            }
        }
    }
}
