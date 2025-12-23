import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct AudiobookPlayerView: View {
    private let bookData: PlayerBookData?

    @State private var chapterProgress: Double = 0.0
    @State private var isPlaying = false
    @State private var playbackRate: Double = 1.0
    @State private var volume: Double = 1.0
    @State private var sleepTimerActive = false
    @State private var sleepTimerRemaining: TimeInterval? = nil
    @State private var sleepTimerType: SleepTimerType? = nil
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

    public init(bookData: PlayerBookData?) {
        self.bookData = bookData
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
            .onAppear {
                #if os(iOS)
                CarPlayCoordinator.shared.isPlayerViewActive = true
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
                CarPlayCoordinator.shared.isPlayerViewActive = false
                #endif

                progressTimer?.invalidate()
                progressTimer = nil
                syncTimer?.invalidate()
                syncTimer = nil

                Task {
                    await syncProgressToServer(reason: .userClosedBook)

                    if let observerID = stateObserverID {
                        await AudiobookActor.shared.removeStateObserver(id: observerID)
                    }
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
    }

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
                chapterDuration: chapterDuration,
                totalRemaining: totalRemaining,
                playbackRate: playbackRate,
                volume: volume,
                isPlaying: isPlaying,
                sleepTimerActive: sleepTimerActive,
                sleepTimerRemaining: sleepTimerRemaining,
                sleepTimerType: sleepTimerType
            ),
            mode: .audiobook,
            chapterProgress: $chapterProgress,
            chapters: chapters,
            progressData: progressMessage.map { msg in
                ProgressData(
                    chapterLabel: msg.chapterLabel,
                    chapterCurrentPage: msg.chapterCurrentPage,
                    chapterTotalPages: msg.chapterTotalPages,
                    chapterCurrentSecondsAudio: msg.chapterCurrentSecondsAudio,
                    chapterTotalSecondsAudio: msg.chapterTotalSecondsAudio,
                    bookCurrentSecondsAudio: msg.bookCurrentSecondsAudio,
                    bookTotalSecondsAudio: msg.bookTotalSecondsAudio,
                    bookCurrentFraction: msg.bookCurrentFraction
                )
            },
            onChapterSelected: { href in
                Task {
                    await AudiobookActor.shared.seekToChapter(href: href)
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
                sleepTimerActive = true
                sleepTimerRemaining = duration
                sleepTimerType = type
            },
            onSleepTimerCancel: {
                sleepTimerActive = false
                sleepTimerRemaining = nil
                sleepTimerType = nil
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
            seekWhileDragging: false
        )
    }

    private func loadAudiobook() async {
        guard let bookData = bookData, let mediaURL = bookData.localMediaPath else {
            errorMessage = "No audiobook file available"
            isLoading = false
            return
        }

        await SMILPlayerActor.shared.cleanup()
        debugLog("[AudiobookPlayerView] Cleaned up SMILPlayerActor before loading audiobook")

        do {
            let loadedMetadata = try await AudiobookActor.shared.validateAndLoadAudiobook(
                url: mediaURL
            )
            metadata = loadedMetadata

            chapters = loadedMetadata.chapters.map { chapter in
                ChapterItem(
                    id: chapter.href,
                    label: chapter.title,
                    href: chapter.href,
                    level: 0
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
                chapterIndex: index,
                chapterLabel: chapter.title,
                chapterCurrentPage: nil,
                chapterTotalPages: nil,
                chapterCurrentSecondsAudio: timeInChapter,
                chapterTotalSecondsAudio: chapter.duration,
                bookCurrentSecondsAudio: currentTime,
                bookTotalSecondsAudio: totalDuration,
                bookCurrentFraction: totalDuration > 0 ? currentTime / totalDuration : 0,
                generatedAt: Date().timeIntervalSince1970
            )
        } else {
            currentChapterTitle = "Unknown Chapter"
            chapterDuration = 0
            chapterProgress = 0

            progressMessage = PlaybackProgressUpdateMessage(
                chapterIndex: nil,
                chapterLabel: nil,
                chapterCurrentPage: nil,
                chapterTotalPages: nil,
                chapterCurrentSecondsAudio: nil,
                chapterTotalSecondsAudio: nil,
                bookCurrentSecondsAudio: currentTime,
                bookTotalSecondsAudio: totalDuration,
                bookCurrentFraction: totalDuration > 0 ? currentTime / totalDuration : 0,
                generatedAt: Date().timeIntervalSince1970
            )
        }

        totalRemaining = max(0, totalDuration - currentTime)
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
                await AudiobookActor.shared.seekToChapter(href: currentChapter.href)
                lastRestartTime = now
            } else if currentIndex > 0 {
                let prevChapter = metadata.chapters[currentIndex - 1]
                debugLog(
                    "[AudiobookPlayerView] Navigating to previous chapter: \(prevChapter.title)"
                )
                await AudiobookActor.shared.seekToChapter(href: prevChapter.href)
                lastRestartTime = nil
            } else {
                debugLog("[AudiobookPlayerView] Already at beginning of first chapter")
                await AudiobookActor.shared.seekToChapter(href: currentChapter.href)
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
            await AudiobookActor.shared.seekToChapter(href: nextChapter.href)
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

        let audioHref = bookData?.localMediaPath?.lastPathComponent ?? "audiobook.m4b"
        let timeOffset = state.currentTime

        let locator = BookLocator(
            href: audioHref,
            type: "audio/mp4",
            title: chapter?.title,
            locations: BookLocator.Locations(
                fragments: ["t=\(timeOffset)"],
                progression: chapterProgression,
                position: nil,
                totalProgression: currentProgress,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil
            ),
            text: nil
        )

        debugLog(
            "[AudiobookPlayerView] Syncing progress (reason: \(reason.rawValue)) - href: \(audioHref), type: audio/mp4, t=\(String(format: "%.1f", timeOffset))s, chapterProg: \(String(format: "%.1f%%", chapterProgression * 100)), totalProg: \(String(format: "%.1f%%", currentProgress * 100))"
        )

        let timestamp = Date().timeIntervalSince1970 * 1000

        let result = await ProgressSyncActor.shared.syncProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
            reason: reason
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
}

#if DEBUG
struct AudiobookPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        AudiobookPlayerView(bookData: nil)
            .frame(width: 420, height: 768)
    }
}
#endif
