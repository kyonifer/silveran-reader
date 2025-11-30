import Foundation
import WebKit

/// MediaOverlayManager - Single source of truth for audio sync decisions
///
/// Responsibilities:
/// - Decide when audio playhead should move
/// - Track current audio position
/// - Handle chapter navigation without loops
/// - Manage sync mode (enabled/disabled)
@MainActor
@Observable
class MediaOverlayManager {
    // MARK: - Properties

    private let bookStructure: [SectionInfo]

    /// Bridge to send highlight commands to JS (rendering only, no audio control)
    weak var commsBridge: WebViewCommsBridge?

    /// Reference to SMILPlayerManager for direct audio control
    weak var smilPlayerManager: SMILPlayerManager?

    /// Reference to EbookProgressManager for coordinating progress sync
    weak var progressManager: EbookProgressManager?

    /// Internal state tracking for play/pause
    var isPlaying: Bool = false

    /// Timer for delayed page flips during fractional sentence playback
    private var pageFlipTimer: Timer?

    /// Whether audio is synced to view navigation (true) or detached (false)
    var syncEnabled: Bool = true

    /// Current playback rate/speed (1.0 = normal, 1.5 = 1.5x speed, etc.)
    var playbackRate: Double = 1.0

    /// Current volume (0.0 = mute, 1.0 = full volume)
    var volume: Double = 1.0

    // MARK: - Sleep Timer State

    /// Whether sleep timer is currently active
    var sleepTimerActive: Bool = false

    /// Remaining time on sleep timer (seconds)
    var sleepTimerRemaining: TimeInterval? = nil

    /// Type of sleep timer (duration or end-of-chapter)
    var sleepTimerType: SleepTimerType? = nil

    /// Internal sleep timer instance
    private var sleepTimer: Timer? = nil

    // MARK: - Audio Progress State

    /// Current elapsed time in the current chapter (seconds)
    var chapterElapsedSeconds: Double? = nil

    /// Total duration of the current chapter (seconds)
    var chapterTotalSeconds: Double? = nil

    /// Current elapsed time in the entire book (seconds)
    var bookElapsedSeconds: Double? = nil

    /// Total duration of the entire book (seconds)
    var bookTotalSeconds: Double? = nil

    /// Current fragment being played (format: "href#anchor", e.g., "text/part0007.html#para-123")
    var currentFragment: String? = nil

    // MARK: - Computed Properties

    /// Returns true if the book has any media overlay (SMIL entries)
    var hasMediaOverlay: Bool {
        bookStructure.contains { !$0.mediaOverlay.isEmpty }
    }

    /// Returns sections that are in the TOC (have labels)
    var tocSections: [SectionInfo] {
        bookStructure.filter { $0.label != nil }
    }

    /// Computed time remaining in current chapter (adjusts for playback rate)
    var chapterTimeRemaining: TimeInterval? {
        guard let total = chapterTotalSeconds,
              let elapsed = chapterElapsedSeconds,
              playbackRate > 0 else {
            return nil
        }
        let remaining = max(total - elapsed, 0)
        return remaining / playbackRate
    }

    /// Computed time remaining in entire book (adjusts for playback rate)
    var bookTimeRemaining: TimeInterval? {
        guard let total = bookTotalSeconds,
              let elapsed = bookElapsedSeconds,
              playbackRate > 0 else {
            return nil
        }
        let remaining = max(total - elapsed, 0)
        return remaining / playbackRate
    }

    // MARK: - Initialization

    init(bookStructure: [SectionInfo], bridge: WebViewCommsBridge) {
        self.bookStructure = bookStructure
        self.commsBridge = bridge
        debugLog("[MOM] MediaOverlayManager initialized")
        debugLog("[MOM]   Total sections: \(bookStructure.count)")
        debugLog("[MOM]   Sections with audio: \(bookStructure.filter { !$0.mediaOverlay.isEmpty }.count)")
        debugLog("[MOM]   TOC sections: \(tocSections.count)")

        let sectionsToShow = min(20, bookStructure.count)
        debugLog("[MOM] First \(sectionsToShow) sections:")

        for i in 0..<sectionsToShow {
            let section = bookStructure[i]
            let label = section.label ?? "(no label)"
            let level = section.level?.description ?? "nil"
            let smilCount = section.mediaOverlay.count

            debugLog("[MOM]   [\(i)] \(section.id) - \(label) (level: \(level), SMIL entries: \(smilCount))")

            if !section.mediaOverlay.isEmpty {
                let smilToShow = min(10, section.mediaOverlay.count)
                debugLog("[MOM]     First \(smilToShow) SMIL entries:")

                for j in 0..<smilToShow {
                    let entry = section.mediaOverlay[j]
                    debugLog("[MOM]       [\(j)] #\(entry.textId) @ \(entry.textHref)")
                    debugLog("[MOM]            audio: \(entry.audioFile) [\(String(format: "%.3f", entry.begin))s - \(String(format: "%.3f", entry.end))s]")
                    debugLog("[MOM]            cumSum: \(String(format: "%.3f", entry.cumSumAtEnd))s")
                }

                if section.mediaOverlay.count > smilToShow {
                    debugLog("[MOM]       ... and \(section.mediaOverlay.count - smilToShow) more entries")
                }
            }
        }

        if bookStructure.count > sectionsToShow {
            debugLog("[MOM]   ... and \(bookStructure.count - sectionsToShow) more sections")
        }
    }

    // MARK: - Navigation Handlers

    /// Called when user selects a chapter directly (via sidebar/chapter button)
    /// Seeks audio to the first SMIL element of that chapter
    func handleUserChapterNavigation(sectionIndex: Int) async {
        debugLog("[MOM] User chapter nav → Section.\(sectionIndex)")

        guard syncEnabled else {
            debugLog("[MOM] Sync disabled - audio will not follow chapter navigation")
            return
        }

        guard let sectionInfo = getSection(at: sectionIndex) else {
            debugLog("[MOM] Invalid section index: \(sectionIndex)")
            return
        }

        guard !sectionInfo.mediaOverlay.isEmpty else {
            debugLog("[MOM] Section \(sectionIndex) has no audio, skipping sync")
            return
        }

        let firstEntry = sectionInfo.mediaOverlay[0]
        debugLog("[MOM] Chapter has audio - seeking to first fragment: \(firstEntry.textId)")
        await handleSeekEvent(sectionIndex: sectionIndex, anchor: firstEntry.textId)
    }

    /// Called when user initiates navigation (arrow keys, swipe, progress seek)
    /// This is called after a debounce period to handle the final settled location
    func handleUserNavEvent(section: Int, page: Int, totalPages: Int) async {
        debugLog("[MOM] User nav → Section.\(section): \(page)/\(totalPages)")

        guard syncEnabled else {
            debugLog("[MOM] Sync disabled - audio will not follow page navigation")
            return
        }

        guard let sectionInfo = getSection(at: section) else {
            debugLog("[MOM] Invalid section index: \(section)")
            return
        }

        guard !sectionInfo.mediaOverlay.isEmpty else {
            debugLog("[MOM] Section \(section) has no audio, skipping sync")
            return
        }

        if page == 1 {
            debugLog("[MOM] First page of section with audio - seeking to first fragment: \(sectionInfo.mediaOverlay[0].textId)")
            await handleSeekEvent(sectionIndex: section, anchor: sectionInfo.mediaOverlay[0].textId)
            return
        }

        debugLog("[MOM] Mid-chapter page (\(page)), querying fully visible elements")

        guard let visibleIds = try? await commsBridge?.sendJsGetFullyVisibleElementIds(),
              !visibleIds.isEmpty else {
            debugLog("[MOM] No visible elements found, skipping audio sync")
            return
        }

        for smilEntry in sectionInfo.mediaOverlay {
            if visibleIds.contains(smilEntry.textId) {
                debugLog("[MOM] Syncing audio to first visible SMIL element: \(smilEntry.textId)")
                await handleSeekEvent(sectionIndex: section, anchor: smilEntry.textId)
                return
            }
        }

        debugLog("[MOM] No SMIL match found on page, audio position unchanged")
    }

    /// Called when navigation occurs naturally (media overlay auto-progression, resize events)
    /// Excludes user-initiated actions which are handled by handleUserNavEvent
    /// This also handles media overlay progress events (anchor changes during playback)
    func handleNaturalNavEvent(section: Int, page: Int, totalPages: Int) async {
        debugLog("[MOM] Natural nav → Section.\(section): \(page)/\(totalPages)")
    }

    /// Called when seeking audio to a specific location in the book
    /// Triggers:
    /// - User double-clicks on a sentence in the reader
    /// - Book opens at last reading position (future)
    /// Only seeks if the exact fragment exists in bookStructure for the requested section
    func handleSeekEvent(sectionIndex: Int, anchor: String) async {
        debugLog("[MOM] handleSeekEvent - section: \(sectionIndex), anchor: \(anchor)")

        guard let section = getSection(at: sectionIndex) else {
            debugLog("[MOM] ERROR: handleSeekEvent - invalid section index: \(sectionIndex)")
            return
        }

        let fragmentExists = section.mediaOverlay.contains { $0.textId == anchor }

        if !fragmentExists {
            debugLog("[MOM] ERROR: handleSeekEvent - fragment '\(anchor)' not found in section \(sectionIndex) (\(section.id))")
            debugLog("[MOM]   Available fragments in section: \(section.mediaOverlay.map { $0.textId }.prefix(10).joined(separator: ", "))")
            return
        }

        debugLog("[MOM] handleSeekEvent - fragment found, seeking to \(section.id)#\(anchor)")

        guard let smilPlayerManager = smilPlayerManager else {
            debugLog("[MOM] handleSeekEvent - no smilPlayerManager available")
            return
        }

        let wasPlaying = isPlaying

        let success = await smilPlayerManager.seekToFragment(sectionIndex: sectionIndex, textId: anchor)
        if success {
            debugLog("[MOM] handleSeekEvent - seek successful")
            await sendHighlightCommand(href: section.id, textId: anchor)

            if wasPlaying {
                debugLog("[MOM] handleSeekEvent - resuming playback")
                smilPlayerManager.play()
            }
        } else {
            debugLog("[MOM] handleSeekEvent - seek failed")
        }
    }

    func togglePlaying() async {
        guard let smilPlayerManager = smilPlayerManager else {
            debugLog("[MOM] togglePlaying() - no smilPlayerManager available")
            return
        }

        if isPlaying {
            debugLog("[MOM] togglePlaying() - pausing")
            isPlaying = false
            smilPlayerManager.pause()
            pageFlipTimer?.invalidate()
            pageFlipTimer = nil
            debugLog("[MOM] togglePlaying() - paused")
        } else {
            debugLog("[MOM] togglePlaying() - starting")
            isPlaying = true

            if smilPlayerManager.state == .idle {
                let (sectionIndex, entryIndex) = smilPlayerManager.getCurrentPosition()
                if let section = getSection(at: sectionIndex),
                   entryIndex < section.mediaOverlay.count {
                    let entry = section.mediaOverlay[entryIndex]
                    debugLog("[MOM] togglePlaying() - initializing audio at section \(sectionIndex), entry \(entryIndex)")
                    await smilPlayerManager.setCurrentEntry(
                        sectionIndex: sectionIndex,
                        entryIndex: entryIndex,
                        audioFile: entry.audioFile,
                        beginTime: entry.begin,
                        endTime: entry.end
                    )
                }
            }

            smilPlayerManager.play()
            if let entry = smilPlayerManager.getCurrentEntry() {
                let (sectionIndex, _) = smilPlayerManager.getCurrentPosition()
                if let section = getSection(at: sectionIndex) {
                    await sendHighlightCommand(href: section.id, textId: entry.textId)
                }
            }
            debugLog("[MOM] togglePlaying() - started")
        }
    }

    func nextSentence() {
        guard hasMediaOverlay else {
            debugLog("[MOM] nextSentence() - no media overlay available")
            return
        }

        guard let smilPlayerManager = smilPlayerManager else {
            debugLog("[MOM] nextSentence() - no smilPlayerManager available")
            return
        }

        let (sectionIndex, entryIndex) = smilPlayerManager.getCurrentPosition()
        guard let section = getSection(at: sectionIndex) else {
            debugLog("[MOM] nextSentence() - invalid section")
            return
        }

        let nextEntryIndex = entryIndex + 1
        if nextEntryIndex < section.mediaOverlay.count {
            let entry = section.mediaOverlay[nextEntryIndex]
            debugLog("[MOM] nextSentence() - advancing to entry \(nextEntryIndex) in section \(sectionIndex)")
            Task {
                let wasPlaying = isPlaying
                _ = await smilPlayerManager.seekToFragment(sectionIndex: sectionIndex, textId: entry.textId)
                try? await commsBridge?.sendJsGoToHrefCommand(href: "\(section.id)#\(entry.textId)")
                await sendHighlightCommand(href: section.id, textId: entry.textId)
                if wasPlaying { smilPlayerManager.play() }
            }
        } else {
            for nextSectionIndex in (sectionIndex + 1)..<bookStructure.count {
                let nextSection = bookStructure[nextSectionIndex]
                if !nextSection.mediaOverlay.isEmpty {
                    let entry = nextSection.mediaOverlay[0]
                    debugLog("[MOM] nextSentence() - advancing to section \(nextSectionIndex)")
                    Task {
                        let wasPlaying = isPlaying
                        _ = await smilPlayerManager.seekToFragment(sectionIndex: nextSectionIndex, textId: entry.textId)
                        try? await commsBridge?.sendJsGoToHrefCommand(href: "\(nextSection.id)#\(entry.textId)")
                        await sendHighlightCommand(href: nextSection.id, textId: entry.textId)
                        if wasPlaying { smilPlayerManager.play() }
                    }
                    return
                }
            }
            debugLog("[MOM] nextSentence() - at end of book")
        }
    }

    func prevSentence() {
        guard hasMediaOverlay else {
            debugLog("[MOM] prevSentence() - no media overlay available")
            return
        }

        guard let smilPlayerManager = smilPlayerManager else {
            debugLog("[MOM] prevSentence() - no smilPlayerManager available")
            return
        }

        let (sectionIndex, entryIndex) = smilPlayerManager.getCurrentPosition()

        if entryIndex > 0 {
            guard let section = getSection(at: sectionIndex) else {
                debugLog("[MOM] prevSentence() - invalid section")
                return
            }
            let entry = section.mediaOverlay[entryIndex - 1]
            debugLog("[MOM] prevSentence() - going to entry \(entryIndex - 1) in section \(sectionIndex)")
            Task {
                let wasPlaying = isPlaying
                _ = await smilPlayerManager.seekToFragment(sectionIndex: sectionIndex, textId: entry.textId)
                try? await commsBridge?.sendJsGoToHrefCommand(href: "\(section.id)#\(entry.textId)")
                await sendHighlightCommand(href: section.id, textId: entry.textId)
                if wasPlaying { smilPlayerManager.play() }
            }
        } else {
            for prevSectionIndex in (0..<sectionIndex).reversed() {
                let prevSection = bookStructure[prevSectionIndex]
                if !prevSection.mediaOverlay.isEmpty {
                    let lastEntryIndex = prevSection.mediaOverlay.count - 1
                    let entry = prevSection.mediaOverlay[lastEntryIndex]
                    debugLog("[MOM] prevSentence() - going to section \(prevSectionIndex), entry \(lastEntryIndex)")
                    Task {
                        let wasPlaying = isPlaying
                        _ = await smilPlayerManager.seekToFragment(sectionIndex: prevSectionIndex, textId: entry.textId)
                        try? await commsBridge?.sendJsGoToHrefCommand(href: "\(prevSection.id)#\(entry.textId)")
                        await sendHighlightCommand(href: prevSection.id, textId: entry.textId)
                        if wasPlaying { smilPlayerManager.play() }
                    }
                    return
                }
            }
            debugLog("[MOM] prevSentence() - at beginning of book")
        }
    }

    /// Enable or disable audio sync with page navigation
    func setSyncMode(enabled: Bool) {
        syncEnabled = enabled
        debugLog("[MOM] Sync mode: \(enabled ? "enabled" : "disabled") - audio will \(enabled ? "follow" : "not follow") page navigation")

        if !enabled {
            Task {
                try? await commsBridge?.sendJsClearHighlight()
            }
            pageFlipTimer?.invalidate()
            pageFlipTimer = nil
        }
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        debugLog("[MOM] Playback rate set to: \(rate)x")
        smilPlayerManager?.setPlaybackRate(rate)
    }

    /// Set volume level for audio narration (macOS only)
    func setVolume(_ newVolume: Double) {
        let clampedVolume = max(0.0, min(1.0, newVolume))
        volume = clampedVolume
        debugLog("[MOM] Volume set to: \(Int(clampedVolume * 100))%")
        smilPlayerManager?.setVolume(clampedVolume)
    }

    func startSleepTimer(duration: TimeInterval?, type: SleepTimerType) {
        cancelSleepTimer()

        sleepTimerType = type

        if type == .endOfChapter {
            debugLog("[MOM] Sleep timer: will pause at end of current chapter")
            sleepTimerActive = true
            sleepTimerRemaining = nil
        } else if let duration = duration {
            debugLog("[MOM] Sleep timer: starting \(Int(duration))s countdown")
            sleepTimerActive = true
            sleepTimerRemaining = duration

            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.updateSleepTimer()
                }
            }
        }
    }

    func cancelSleepTimer() {
        debugLog("[MOM] Sleep timer cancelled")
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerActive = false
        sleepTimerRemaining = nil
        sleepTimerType = nil
    }

    /// Internal: Update sleep timer countdown
    private func updateSleepTimer() async {
        guard sleepTimerActive else { return }

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
            debugLog("[MOM] Sleep timer expired - pausing playback")
            cancelSleepTimer()
            await progressManager?.togglePlaying()
        }
    }

    /// Check if chapter ended (for end-of-chapter sleep timer)
    func checkChapterEndForSleepTimer(message: MediaOverlayProgressMessage) {
        guard sleepTimerActive,
              sleepTimerType == .endOfChapter,
              isPlaying else { return }

        guard let chapterElapsed = message.chapterElapsedSeconds,
              let chapterTotal = message.chapterTotalSeconds else { return }

        if chapterElapsed >= chapterTotal - 0.5 {
            debugLog("[MOM] End of chapter reached - sleep timer pausing playback")
            Task {
                cancelSleepTimer()
                await progressManager?.togglePlaying()
            }
        }
    }

    /// Cleanup when closing the book (stops audio playback and sleep timer)
    func cleanup() async {
        debugLog("[MOM] MediaOverlayManager cleanup - stopping audio playback and sleep timer")

        cancelSleepTimer()
        pageFlipTimer?.invalidate()
        pageFlipTimer = nil

        guard isPlaying else {
            debugLog("[MOM] Audio not playing, no cleanup needed")
            return
        }

        isPlaying = false
        smilPlayerManager?.pause()
        try? await commsBridge?.sendJsClearHighlight()
        debugLog("[MOM] Audio stopped successfully")
    }

    /// Handle progress update from media overlay (called via bridge)
    func handleProgressUpdate(_ message: MediaOverlayProgressMessage) {
        chapterElapsedSeconds = message.chapterElapsedSeconds
        chapterTotalSeconds = message.chapterTotalSeconds
        bookElapsedSeconds = message.bookElapsedSeconds
        bookTotalSeconds = message.bookTotalSeconds
        currentFragment = message.currentFragment

        checkChapterEndForSleepTimer(message: message)

        debugLog("[MOM] Audio progress: chapter \(message.chapterElapsedSeconds?.description ?? "nil")/\(message.chapterTotalSeconds?.description ?? "nil")s, book \(message.bookElapsedSeconds?.description ?? "nil")/\(message.bookTotalSeconds?.description ?? "nil")s, fragment: \(message.currentFragment ?? "nil")")
    }

    // MARK: - Helpers

    func getSection(byId id: String) -> SectionInfo? {
        bookStructure.first { $0.id == id }
    }

    func getSection(at index: Int) -> SectionInfo? {
        guard index >= 0 && index < bookStructure.count else { return nil }
        return bookStructure[index]
    }

    /// Find SMIL entry by text ID in a specific section
    func findSMILEntry(textId: String, in sectionIndex: Int) -> SMILEntry? {
        guard let section = getSection(at: sectionIndex) else { return nil }
        return section.mediaOverlay.first { $0.textId == textId }
    }

    // MARK: - Highlight and Page Flip

    /// Send highlight command to JS for the current fragment
    private func sendHighlightCommand(href: String, textId: String) async {
        guard syncEnabled else { return }

        do {
            try await commsBridge?.sendJsHighlightFragment(href: href, textId: textId)
            debugLog("[MOM] Highlight command sent: \(href)#\(textId)")
        } catch {
            debugLog("[MOM] Error sending highlight command: \(error)")
        }
    }

    /// Handle element visibility message from JS (for page flip timing)
    func handleElementVisibility(_ message: ElementVisibilityMessage) {
        pageFlipTimer?.invalidate()
        pageFlipTimer = nil

        guard isPlaying, syncEnabled else { return }

        debugLog("[MOM] Element visibility: textId=\(message.textId), visible=\(message.visibleRatio), offScreen=\(message.offScreenRatio)")

        if message.offScreenRatio >= 0.9 {
            debugLog("[MOM] Element almost fully off-screen, flipping immediately")
            Task {
                try? await commsBridge?.sendJsGoRightCommand()
            }
        } else if message.offScreenRatio >= 0.1 && message.visibleRatio < 0.98 {
            guard let entry = smilPlayerManager?.getCurrentEntry() else { return }
            let entryDuration = entry.end - entry.begin
            let earlyOffset = 1.0
            let delay = max(0, (entryDuration * message.visibleRatio / playbackRate) - earlyOffset)

            debugLog("[MOM] Scheduling page flip in \(String(format: "%.2f", delay))s (entry duration: \(String(format: "%.2f", entryDuration))s, visible: \(String(format: "%.0f", message.visibleRatio * 100))%)")

            pageFlipTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.isPlaying == true, self?.syncEnabled == true else { return }
                    debugLog("[MOM] Page flip timer fired")
                    try? await self?.commsBridge?.sendJsGoRightCommand()
                }
            }
        }
    }

    /// Compute audio progress from SMILPlayerManager state
    func updateProgressFromPlayer() {
        guard let smilPlayer = smilPlayerManager else { return }

        let (sectionIndex, entryIndex) = smilPlayer.getCurrentPosition()
        guard sectionIndex < bookStructure.count else { return }
        let section = bookStructure[sectionIndex]
        guard entryIndex < section.mediaOverlay.count else { return }

        let entry = section.mediaOverlay[entryIndex]
        let currentAudioTime = smilPlayer.currentTime

        let chapterElapsed = entry.cumSumAtEnd - (entry.end - currentAudioTime)
        chapterElapsedSeconds = max(0, chapterElapsed)

        if let lastEntry = section.mediaOverlay.last {
            chapterTotalSeconds = lastEntry.cumSumAtEnd
        }

        var bookElapsed: Double = 0
        for i in 0..<sectionIndex {
            if let last = bookStructure[i].mediaOverlay.last {
                bookElapsed += last.cumSumAtEnd
            }
        }
        bookElapsed += chapterElapsed
        bookElapsedSeconds = max(0, bookElapsed)

        var bookTotal: Double = 0
        for section in bookStructure {
            if let last = section.mediaOverlay.last {
                bookTotal += last.cumSumAtEnd
            }
        }
        bookTotalSeconds = bookTotal

        currentFragment = "\(section.id)#\(entry.textId)"
    }
}

// MARK: - SMILPlayerManagerDelegate

extension MediaOverlayManager: SMILPlayerManagerDelegate {
    func smilPlayerDidAdvanceToEntry(sectionIndex: Int, entryIndex: Int, entry: SMILEntry) {
        guard let section = getSection(at: sectionIndex) else { return }

        debugLog("[MOM] SMILPlayer advanced to: section=\(sectionIndex), entry=\(entryIndex), textId=\(entry.textId)")

        updateProgressFromPlayer()

        if syncEnabled {
            Task {
                try? await commsBridge?.sendJsGoToHrefCommand(href: "\(section.id)#\(entry.textId)")
                await sendHighlightCommand(href: section.id, textId: entry.textId)
            }
        }
    }

    func smilPlayerDidFinishBook() {
        debugLog("[MOM] SMILPlayer finished book")
        isPlaying = false
        pageFlipTimer?.invalidate()
        pageFlipTimer = nil
        Task {
            try? await commsBridge?.sendJsClearHighlight()
        }
    }

    func smilPlayerDidUpdateTime(currentTime: Double, sectionIndex: Int, entryIndex: Int) {
        updateProgressFromPlayer()
    }

    func smilPlayerShouldAdvanceToNextSection(fromSection: Int) -> Bool {
        if sleepTimerActive && sleepTimerType == .endOfChapter {
            debugLog("[MOM] Sleep timer blocking section advance (end of chapter)")
            isPlaying = false
            cancelSleepTimer()
            return false
        }
        return true
    }

    func smilPlayerRemoteCommandReceived(command: RemoteCommand) {
        debugLog("[MOM] Remote command received: \(command)")
        switch command {
        case .play, .pause:
            Task { await togglePlaying() }
        case .skipForward(let seconds):
            smilPlayerManager?.seek(to: (smilPlayerManager?.currentTime ?? 0) + seconds)
        case .skipBackward(let seconds):
            smilPlayerManager?.seek(to: max(0, (smilPlayerManager?.currentTime ?? 0) - seconds))
        case .seekTo(let position):
            smilPlayerManager?.seek(to: position)
        }
    }
}
