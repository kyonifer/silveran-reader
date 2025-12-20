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
        let chapterNum = bookStructure
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
        configureAudioSession()
        setupRemoteCommands()
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

    func loadBook(_ entry: WatchBookEntry) async {
        bookTitle = entry.title
        currentBookId = entry.uuid
        hasRestoredPosition = false
        isLoadingPosition = true

        let bookDir = WatchStorageManager.shared.getBookDirectory(uuid: entry.uuid, category: entry.category)
        epubURL = bookDir.appendingPathComponent("book.epub")

        guard let url = epubURL, FileManager.default.fileExists(atPath: url.path) else {
            debugLog("[WatchPlayerViewModel] EPUB file not found")
            isLoadingPosition = false
            return
        }

        do {
            try await SMILPlayerActor.shared.loadBook(
                epubPath: url,
                bookId: entry.uuid,
                title: entry.title,
                author: nil
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

            await restorePositionFromCloudKit(bookId: entry.uuid)
            isLoadingPosition = false
            await loadCurrentSectionHTML()
        } catch {
            debugLog("[WatchPlayerViewModel] Failed to load book: \(error)")
            isLoadingPosition = false
        }
    }

    private func handleStateUpdate(_ state: SMILPlaybackState) {
        let sectionChanged = state.currentSectionIndex != currentSectionIndex

        isPlaying = state.isPlaying
        currentTime = state.chapterElapsed
        currentSectionIndex = state.currentSectionIndex
        currentEntryIndex = state.currentEntryIndex
        playbackRate = state.playbackRate
        bookElapsed = state.bookElapsed
        bookDuration = state.bookTotal

        if sectionChanged {
            chapterTitle = state.chapterLabel ?? chapterLabel(forSectionIndex: state.currentSectionIndex)
            chapterDuration = state.chapterTotal
            Task {
                await loadCurrentSectionHTML()
            }
            syncProgressToCloudKit()
        }

        if !isPlaying && Date().timeIntervalSince(lastSyncTime) > syncDebounceInterval {
            syncProgressToCloudKit()
        }

        updateNowPlayingInfo()
    }

    // MARK: - Playback Controls

    func playPause() {
        Task { @SMILPlayerActor in
            try? await SMILPlayerActor.shared.togglePlayPause()
        }
    }

    func skipForward() {
        Task { @SMILPlayerActor in
            await SMILPlayerActor.shared.skipForward(seconds: 30)
        }
    }

    func skipBackward() {
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

        Task {
            await jumpToChapter(targetIndex)
        }
    }

    func jumpToChapter(_ sectionIndex: Int) async {
        guard sectionIndex >= 0, sectionIndex < bookStructure.count else { return }

        let section = bookStructure[sectionIndex]
        guard !section.mediaOverlay.isEmpty else { return }

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

        if let elementHTML = EPUBContentLoader.extractElement(from: currentSectionHTML, elementId: entry.textId) {
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

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            debugLog("[WatchPlayerViewModel] Failed to configure audio session: \(error)")
        }
    }

    // MARK: - Now Playing

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if !self.isPlaying {
                    self.playPause()
                }
            }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying {
                    self.playPause()
                }
            }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.playPause()
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.nextChapter()
            }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.previousChapter()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: chapterDuration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if !chapterTitle.isEmpty {
            info[MPMediaItemPropertyArtist] = chapterTitle
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

    // MARK: - CloudKit Sync

    private func restorePositionFromCloudKit(bookId: String) async {
        debugLog("[WatchPlayerViewModel] Fetching position from CloudKit for \(bookId)")

        guard let cloudKitProgress = await CloudKitSyncActor.shared.fetchProgress(for: bookId) else {
            debugLog("[WatchPlayerViewModel] No CloudKit position found")
            hasRestoredPosition = true
            return
        }

        let locator = cloudKitProgress.locator
        let href = locator.href
        let textId = locator.locations?.fragments?.first

        debugLog("[WatchPlayerViewModel] CloudKit href: \(href), fragment: \(textId ?? "nil")")

        if let textId = textId {
            // Find section by matching entry.textHref
            if let sectionIndex = bookStructure.firstIndex(where: { section in
                section.mediaOverlay.contains { $0.textHref == href }
            }) {
                debugLog("[WatchPlayerViewModel] Seeking to section \(sectionIndex), textId: \(textId)")
                let success = await SMILPlayerActor.shared.seekToFragment(sectionIndex: sectionIndex, textId: textId)
                if success {
                    hasRestoredPosition = true
                    return
                }
            } else if let sectionIndex = findSectionIndex(for: href, in: bookStructure) {
                debugLog("[WatchPlayerViewModel] Seeking via findSectionIndex to section \(sectionIndex), textId: \(textId)")
                let success = await SMILPlayerActor.shared.seekToFragment(sectionIndex: sectionIndex, textId: textId)
                if success {
                    hasRestoredPosition = true
                    return
                }
            }
        }

        // Fallback to totalProgression
        let progression = cloudKitProgress.locator.locations?.totalProgression ?? 0
        if progression > 0 {
            debugLog("[WatchPlayerViewModel] Fallback to totalProgression: \(progression)")
            let _ = await SMILPlayerActor.shared.seekToTotalProgression(progression)
        }

        hasRestoredPosition = true
    }

    private func syncProgressToCloudKit() {
        guard let bookId = currentBookId, hasRestoredPosition else { return }

        lastSyncTime = Date()
        let progression = bookDuration > 0 ? bookElapsed / bookDuration : 0
        let timestamp = Date().timeIntervalSince1970 * 1000

        guard currentSectionIndex < bookStructure.count else { return }
        let section = bookStructure[currentSectionIndex]
        guard currentEntryIndex < section.mediaOverlay.count else { return }

        let entry = section.mediaOverlay[currentEntryIndex]

        debugLog("[WatchPlayerViewModel] entry.textHref=\(entry.textHref)")
        debugLog("[WatchPlayerViewModel] entry.textId=\(entry.textId)")

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

        debugLog("[WatchPlayerViewModel] locator.href=\(locator.href)")
        debugLog("[WatchPlayerViewModel] locator.fragments=\(locator.locations?.fragments ?? [])")
        debugLog("[WatchPlayerViewModel] locator.position=\(String(describing: locator.locations?.position))")

        Task {
            let _ = await CloudKitSyncActor.shared.sendProgressToCloudKit(
                bookId: bookId,
                locator: locator,
                timestamp: timestamp
            )
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        if let observerId = stateObserverId {
            Task { @SMILPlayerActor in
                await SMILPlayerActor.shared.removeStateObserver(id: observerId)
                await SMILPlayerActor.shared.cleanup()
            }
        }
        stateObserverId = nil
        isPlaying = false
    }
}
#endif
