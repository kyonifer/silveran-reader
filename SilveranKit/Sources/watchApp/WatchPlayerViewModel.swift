#if os(watchOS)
import AVFoundation
import Foundation
import MediaPlayer
import SilveranKitCommon
import SwiftUI

@MainActor
@Observable
public final class WatchPlayerViewModel: NSObject {
    // MARK: - Playback State

    var isPlaying = false
    var isLoadingPosition = true
    var currentTime: Double = 0
    var chapterDuration: Double = 0
    var bookElapsed: Double = 0
    var bookDuration: Double = 0
    var chapterTitle: String = ""
    var bookTitle: String = ""
    var volume: Double = 1.0
    var playbackRate: Double = 1.0
    var isMuted = false
    private var volumeBeforeMute: Double = 1.0
    private static let volumeKey = "WatchPlayerVolume"
    private static let minimumVolume = 0.05

    // MARK: - Current Position

    var currentSectionIndex: Int = 0
    var currentEntryIndex: Int = 0

    // MARK: - Text Display

    private var currentSectionHTML: String = ""
    private var cachedSectionHref: String = ""

    // MARK: - Private

    private var stateObserverId: UUID?
    private var bookStructure: [SectionInfo] = []
    private var epubURL: URL?
    private var currentBookId: String?
    private var lastSyncTime: Date = .distantPast
    private let syncDebounceInterval: TimeInterval = 10
    private var hasRestoredPosition = false
    private var hasUserProgress = false
    private var periodicSyncTask: Task<Void, Never>?
    private static let periodicSyncInterval: TimeInterval = 60

    // MARK: - Chapter Info

    struct ChapterInfo: Identifiable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    var chapters: [ChapterInfo] {
        bookStructure
            .filter { !$0.mediaOverlay.isEmpty }
            .enumerated()
            .map { (chapterNum, section) in
                ChapterInfo(
                    index: section.index,
                    label: section.label ?? "Chapter \(chapterNum + 1)"
                )
            }
    }

    // MARK: - Computed Properties

    var hasChapters: Bool {
        bookStructure.count > 1
    }

    private func chapterLabel(forSectionIndex sectionIndex: Int) -> String {
        guard sectionIndex < bookStructure.count else { return "Chapter" }
        if let label = bookStructure[sectionIndex].label {
            return label
        }
        let chapterNum =
            bookStructure
            .prefix(sectionIndex + 1)
            .filter { !$0.mediaOverlay.isEmpty }
            .count
        return "Chapter \(chapterNum)"
    }

    var chapterProgress: Double {
        guard chapterDuration > 0 else { return 0 }
        return currentTime / chapterDuration
    }

    var currentTimeFormatted: String {
        formatTime(currentTime)
    }

    var chapterDurationFormatted: String {
        formatTime(chapterDuration)
    }

    // MARK: - Initialization

    override init() {
        super.init()
        loadSavedVolume()
    }

    private func loadSavedVolume() {
        let saved = UserDefaults.standard.double(forKey: Self.volumeKey)
        if saved > 0 {
            volume = max(saved, Self.minimumVolume)
            volumeBeforeMute = volume
        }
    }

    // MARK: - Book Loading

    func loadBook(_ book: BookMetadata) async {
        loadSavedVolume()
        bookTitle = book.title
        currentBookId = book.uuid
        hasRestoredPosition = false
        hasUserProgress = false
        isLoadingPosition = true

        epubURL = await LocalMediaActor.shared.mediaFilePath(for: book.uuid, category: .synced)

        guard let url = epubURL, FileManager.default.fileExists(atPath: url.path) else {
            debugLog("[WatchPlayerViewModel] EPUB file not found")
            isLoadingPosition = false
            return
        }

        do {
            try await SMILPlayerActor.shared.loadBook(
                epubPath: url,
                bookId: book.uuid,
                title: book.title,
                author: book.authors?.first?.name
            )

            bookStructure = await SMILPlayerActor.shared.getBookStructure()
            debugLog("[WatchPlayerViewModel] Loaded book with \(bookStructure.count) sections")

            stateObserverId = await SMILPlayerActor.shared.addStateObserver { [weak self] state in
                self?.handleStateUpdate(state)
            }

            await SMILPlayerActor.shared.setVolume(volume)

            if let firstSection = bookStructure.first(where: { !$0.mediaOverlay.isEmpty }) {
                currentSectionIndex = firstSection.index
                chapterTitle = chapterLabel(forSectionIndex: firstSection.index)
                updateChapterDuration()
            }

            restorePositionFromMetadata(book)
            isLoadingPosition = false
            await loadCurrentSectionHTML()
        } catch {
            debugLog("[WatchPlayerViewModel] Failed to load book: \(error)")
            isLoadingPosition = false
        }
    }

    private func handleStateUpdate(_ state: SMILPlaybackState) {
        let sectionChanged = state.currentSectionIndex != currentSectionIndex
        let playingChanged = state.isPlaying != isPlaying

        isPlaying = state.isPlaying
        currentTime = state.chapterElapsed
        currentSectionIndex = state.currentSectionIndex
        currentEntryIndex = state.currentEntryIndex
        playbackRate = state.playbackRate
        bookElapsed = state.bookElapsed
        bookDuration = state.bookTotal

        if sectionChanged {
            chapterTitle =
                state.chapterLabel ?? chapterLabel(forSectionIndex: state.currentSectionIndex)
            chapterDuration = state.chapterTotal
            Task {
                await loadCurrentSectionHTML()
            }
            syncProgress()
        }

        if playingChanged {
            if isPlaying {
                startPeriodicSync()
            } else {
                stopPeriodicSync()
                syncProgress()
            }
        }
    }

    private func startPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.periodicSyncInterval))
                guard !Task.isCancelled else { break }
                self?.syncProgress()
            }
        }
    }

    private func stopPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
    }

    // MARK: - Playback Controls

    func playPause() {
        hasUserProgress = true
        Task { @SMILPlayerActor in
            try? await SMILPlayerActor.shared.togglePlayPause()
        }
    }

    func skipForward() {
        hasUserProgress = true
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.skipForward(seconds: 30)
        }
    }

    func skipBackward() {
        hasUserProgress = true
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.skipBackward(seconds: 30)
        }
    }

    func setVolume(_ newVolume: Double) {
        volume = newVolume
        isMuted = false
        // Only persist if above minimum (so we don't restore to near-silent)
        if newVolume >= Self.minimumVolume {
            UserDefaults.standard.set(newVolume, forKey: Self.volumeKey)
        }
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.setVolume(newVolume)
        }
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.setPlaybackRate(rate)
        }
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            volume = volumeBeforeMute
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.setVolume(self.volumeBeforeMute)
            }
        } else {
            volumeBeforeMute = volume
            isMuted = true
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.setVolume(0)
            }
        }
    }

    func nextChapter() {
        let nextIndex = currentSectionIndex + 1
        guard nextIndex < bookStructure.count else { return }

        var targetIndex = nextIndex
        while targetIndex < bookStructure.count && bookStructure[targetIndex].mediaOverlay.isEmpty {
            targetIndex += 1
        }
        guard targetIndex < bookStructure.count else { return }

        hasUserProgress = true
        Task {
            await jumpToChapter(targetIndex)
        }
    }

    func previousChapter() {
        let prevIndex = currentSectionIndex - 1
        guard prevIndex >= 0 else { return }

        var targetIndex = prevIndex
        while targetIndex >= 0 && bookStructure[targetIndex].mediaOverlay.isEmpty {
            targetIndex -= 1
        }
        guard targetIndex >= 0 else { return }

        hasUserProgress = true
        Task {
            await jumpToChapter(targetIndex)
        }
    }

    func jumpToChapter(_ sectionIndex: Int) async {
        guard sectionIndex >= 0, sectionIndex < bookStructure.count else { return }

        let section = bookStructure[sectionIndex]
        guard !section.mediaOverlay.isEmpty else { return }

        hasUserProgress = true
        do {
            try await SMILPlayerActor.shared.seekToEntry(sectionIndex: sectionIndex, entryIndex: 0)
        } catch {
            debugLog("[WatchPlayerViewModel] Failed to jump to chapter: \(error)")
        }
    }

    // MARK: - Text Display

    func getTextForEntry(at entryOffset: Int) -> String {
        let targetIndex = currentEntryIndex + entryOffset
        guard currentSectionIndex < bookStructure.count else { return "" }

        let section = bookStructure[currentSectionIndex]
        guard targetIndex >= 0, targetIndex < section.mediaOverlay.count else { return "" }

        let entry = section.mediaOverlay[targetIndex]

        if let elementHTML = EPUBContentLoader.extractElement(
            from: currentSectionHTML,
            elementId: entry.textId
        ) {
            return EPUBContentLoader.stripHTML(elementHTML)
        }

        return ""
    }

    var previousLineText: String { getTextForEntry(at: -1) }
    var currentLineText: String { getTextForEntry(at: 0) }
    var nextLineText: String { getTextForEntry(at: 1) }

    private func loadCurrentSectionHTML() async {
        guard let url = epubURL, currentSectionIndex < bookStructure.count else { return }

        let section = bookStructure[currentSectionIndex]
        let href = section.id

        if href == cachedSectionHref { return }

        do {
            currentSectionHTML = try EPUBContentLoader.loadSection(from: url, href: href)
            cachedSectionHref = href
        } catch {
            debugLog("[WatchPlayerViewModel] Failed to load section HTML: \(error)")
            currentSectionHTML = ""
        }
    }

    // MARK: - Helpers

    private func updateChapterDuration() {
        guard currentSectionIndex < bookStructure.count else { return }
        let section = bookStructure[currentSectionIndex]
        if let lastEntry = section.mediaOverlay.last {
            chapterDuration = lastEntry.end
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Position Restore

    private func restorePositionFromMetadata(_ book: BookMetadata) {
        guard let position = book.position, let locator = position.locator else {
            debugLog("[WatchPlayerViewModel] No saved position for \(book.uuid)")
            hasRestoredPosition = true
            return
        }

        let href = locator.href
        let textId = locator.locations?.fragments?.first

        debugLog(
            "[WatchPlayerViewModel] Restoring position - href: \(href), fragment: \(textId ?? "nil")"
        )

        Task {
            if let textId = textId {
                if let sectionIndex = bookStructure.firstIndex(where: { section in
                    section.mediaOverlay.contains { $0.textHref == href }
                }) {
                    let success = await SMILPlayerActor.shared.seekToFragment(
                        sectionIndex: sectionIndex,
                        textId: textId
                    )
                    if success {
                        hasRestoredPosition = true
                        return
                    }
                } else if let sectionIndex = findSectionIndex(for: href, in: bookStructure) {
                    let success = await SMILPlayerActor.shared.seekToFragment(
                        sectionIndex: sectionIndex,
                        textId: textId
                    )
                    if success {
                        hasRestoredPosition = true
                        return
                    }
                }
            }

            let progression = locator.locations?.totalProgression ?? 0
            if progression > 0 {
                debugLog("[WatchPlayerViewModel] Fallback to totalProgression: \(progression)")
                let _ = await SMILPlayerActor.shared.seekToTotalProgression(progression)
            }

            hasRestoredPosition = true
        }
    }

    private func syncProgress() {
        guard let bookId = currentBookId, hasRestoredPosition, hasUserProgress else { return }

        lastSyncTime = Date()
        let progression = bookDuration > 0 ? bookElapsed / bookDuration : 0
        let timestamp = Date().timeIntervalSince1970 * 1000

        guard currentSectionIndex < bookStructure.count else { return }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return }

        let entry = section.mediaOverlay[currentEntryIndex]

        let locator = BookLocator(
            href: entry.textHref,
            type: "application/xhtml+xml",
            title: nil,
            locations: BookLocator.Locations(
                fragments: [entry.textId],
                progression: chapterProgress,
                position: nil,
                totalProgression: progression,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil
            ),
            text: nil
        )

        Task {
            let _ = await ProgressSyncActor.shared.syncProgress(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp,
                reason: .userPausedPlayback
            )
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        stopPeriodicSync()
        syncProgress()
        if let observerId = stateObserverId {
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.removeStateObserver(id: observerId)
            }
        }
        stateObserverId = nil
        isPlaying = false
    }
}

#endif
