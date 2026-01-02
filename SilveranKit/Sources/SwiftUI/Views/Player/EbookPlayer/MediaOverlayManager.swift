import Foundation
import WebKit

#if os(iOS)
import UIKit
#endif

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
    private let bookId: String
    private let reloadBookIntoActor: () async -> Void
    private let settingsVM: SettingsViewModel

    weak var commsBridge: WebViewCommsBridge?
    weak var progressManager: EbookProgressManager?

    /// Observer ID for SMILPlayerActor state changes
    private var smilObserverId: UUID?

    /// Cached state from SMILPlayerActor
    private(set) var cachedSectionIndex: Int = 0
    private(set) var cachedEntryIndex: Int = 0
    private var lastObservedFragment: String = ""

    var isPlaying: Bool = false
    var isInBackground: Bool = false
    var backgroundAudioPlayed: Bool = false

    /// Timer for delayed page flips during fractional sentence playback
    /// (i.e. when a sentence is half on this page and half on the next)
    private var pageFlipTimer: Timer?

    /// Last time we flipped a page, used to debounce rapid flips
    /// (i.e. when a fractional sentence is paused then play starts again,
    /// causing it to fire right when the next sentence sends a ElementVisibilityMessage)
    private var lastFlipTime: Date?

    /// Whether audio always syncs to view navigation (true) or only when playing (false)
    /// When true: Audio follows all navigation events (page flips, chapter changes) - default behavior
    /// When false: Audio only follows navigation when playing; paused navigation is independent
    private var syncEnabled: Bool { settingsVM.lockViewToAudio }

    var playbackRate: Double = 1.0
    var volume: Double = 1.0

    // MARK: - Sleep Timer State

    var sleepTimerActive: Bool = false
    var sleepTimerRemaining: TimeInterval? = nil
    var sleepTimerType: SleepTimerType? = nil
    private var sleepTimer: Timer? = nil

    // MARK: - Screen Wake Lock State

    #if os(macOS)
    /// Activity token to prevent display sleep on macOS
    private var displaySleepActivity: NSObjectProtocol?
    #endif

    // MARK: - Audio Progress State

    var chapterElapsedSeconds: Double? = nil
    var chapterTotalSeconds: Double? = nil
    var bookElapsedSeconds: Double? = nil
    var bookTotalSeconds: Double? = nil

    /// Current fragment being played (format: "href#anchor", e.g., "text/part0007.html#para-123")
    var currentFragment: String? = nil

    // MARK: - Computed Properties

    /// Returns true if the book has any SMIL entries
    var hasMediaOverlay: Bool {
        bookStructure.contains { !$0.mediaOverlay.isEmpty }
    }

    /// Returns sections that are in the TOC (have labels)
    var tocSections: [SectionInfo] {
        bookStructure.filter { $0.label != nil }
    }

    var chapterTimeRemaining: TimeInterval? {
        guard let total = chapterTotalSeconds,
            let elapsed = chapterElapsedSeconds,
            playbackRate > 0
        else {
            return nil
        }
        let remaining = max(total - elapsed, 0)
        return remaining / playbackRate
    }

    var bookTimeRemaining: TimeInterval? {
        guard let total = bookTotalSeconds,
            let elapsed = bookElapsedSeconds,
            playbackRate > 0
        else {
            return nil
        }
        let remaining = max(total - elapsed, 0)
        return remaining / playbackRate
    }

    // MARK: - Initialization

    init(
        bookStructure: [SectionInfo],
        bookId: String,
        bridge: WebViewCommsBridge,
        settingsVM: SettingsViewModel,
        reloadBookIntoActor: @escaping () async -> Void
    ) {
        self.bookStructure = bookStructure
        self.bookId = bookId
        self.commsBridge = bridge
        self.settingsVM = settingsVM
        self.reloadBookIntoActor = reloadBookIntoActor
        debugLog("[MOM] MediaOverlayManager initialized for book: \(bookId)")
        debugLog("[MOM]   Total sections: \(bookStructure.count)")
        debugLog(
            "[MOM]   Sections with audio: \(bookStructure.filter { !$0.mediaOverlay.isEmpty }.count)"
        )
        debugLog("[MOM]   TOC sections: \(tocSections.count)")

        let sectionsToShow = min(20, bookStructure.count)
        debugLog("[MOM] First \(sectionsToShow) sections:")

        for i in 0..<sectionsToShow {
            let section = bookStructure[i]
            let label = section.label ?? "(no label)"
            let level = section.level?.description ?? "nil"
            let smilCount = section.mediaOverlay.count

            debugLog(
                "[MOM]   [\(i)] \(section.id) - \(label) (level: \(level), SMIL entries: \(smilCount))"
            )

            if !section.mediaOverlay.isEmpty {
                let smilToShow = min(10, section.mediaOverlay.count)
                debugLog("[MOM]     First \(smilToShow) SMIL entries:")

                for j in 0..<smilToShow {
                    let entry = section.mediaOverlay[j]
                    debugLog("[MOM]       [\(j)] #\(entry.textId) @ \(entry.textHref)")
                    debugLog(
                        "[MOM]            audio: \(entry.audioFile) [\(String(format: "%.3f", entry.begin))s - \(String(format: "%.3f", entry.end))s]"
                    )
                    debugLog(
                        "[MOM]            cumSum: \(String(format: "%.3f", entry.cumSumAtEnd))s"
                    )
                }

                if section.mediaOverlay.count > smilToShow {
                    debugLog(
                        "[MOM]       ... and \(section.mediaOverlay.count - smilToShow) more entries"
                    )
                }
            }
        }

        if bookStructure.count > sectionsToShow {
            debugLog("[MOM]   ... and \(bookStructure.count - sectionsToShow) more sections")
        }

        Task {
            await setupActorObserver()
        }
    }

    // MARK: - Actor Observer Setup

    private func setupActorObserver() async {
        let observerId = await SMILPlayerActor.shared.addStateObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActorStateUpdate(state)
            }
        }
        smilObserverId = observerId
        debugLog("[MOM] SMILPlayerActor observer registered: \(observerId)")
    }

    private func handleActorStateUpdate(_ state: SMILPlaybackState) {
        guard state.bookId == bookId else { return }

        let previousSectionIndex = cachedSectionIndex
        let previousEntryIndex = cachedEntryIndex
        let previousFragment = lastObservedFragment

        cachedSectionIndex = state.currentSectionIndex
        cachedEntryIndex = state.currentEntryIndex
        lastObservedFragment = state.currentFragment

        isPlaying = state.isPlaying
        if isInBackground && state.isPlaying {
            backgroundAudioPlayed = true
        }
        chapterElapsedSeconds = state.chapterElapsed
        chapterTotalSeconds = state.chapterTotal
        bookElapsedSeconds = state.bookElapsed
        bookTotalSeconds = state.bookTotal
        currentFragment = state.currentFragment

        let entryChanged =
            (state.currentSectionIndex != previousSectionIndex
                || state.currentEntryIndex != previousEntryIndex)
        let fragmentChanged = state.currentFragment != previousFragment

        if entryChanged && fragmentChanged && state.isPlaying {
            handleEntryAdvancement(
                sectionIndex: state.currentSectionIndex,
                entryIndex: state.currentEntryIndex
            )
        }

        if sleepTimerActive && sleepTimerType == .endOfChapter && state.isPlaying {
            let elapsed = state.chapterElapsed
            let total = state.chapterTotal
            if total > 0 && elapsed >= total - 0.5 {
                debugLog("[MOM] End of chapter reached - sleep timer pausing playback")
                Task {
                    cancelSleepTimer()
                    await progressManager?.togglePlaying()
                }
            }
        }
    }

    private func handleEntryAdvancement(sectionIndex: Int, entryIndex: Int) {
        guard let section = getSection(at: sectionIndex) else { return }
        guard entryIndex < section.mediaOverlay.count else { return }

        let entry = section.mediaOverlay[entryIndex]

        debugLog(
            "[MOM] Actor advanced to: section=\(sectionIndex), entry=\(entryIndex), textId=\(entry.textId)"
        )

        Task {
            await sendHighlightCommand(
                sectionIndex: sectionIndex,
                textId: entry.textId,
                seekToLocation: true
            )
        }
    }

    // MARK: - Navigation Handlers

    /// Called when user selects a chapter directly (via sidebar/chapter button)
    /// Seeks audio to the first SMIL element of that chapter
    func handleUserChapterNavigation(sectionIndex: Int) async {
        debugLog("[MOM] User chapter nav → Section.\(sectionIndex)")

        guard syncEnabled || isPlaying else {
            debugLog(
                "[MOM] Not playing and sync disabled - audio will not follow chapter navigation"
            )
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

        guard syncEnabled || isPlaying else {
            debugLog("[MOM] Not playing and sync disabled - audio will not follow page navigation")
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
            debugLog(
                "[MOM] First page of section with audio - seeking to first fragment: \(sectionInfo.mediaOverlay[0].textId)"
            )
            await handleSeekEvent(sectionIndex: section, anchor: sectionInfo.mediaOverlay[0].textId)
            return
        }

        debugLog("[MOM] Mid-chapter page (\(page)), querying fully visible elements")

        guard let visibleIds = try? await commsBridge?.sendJsGetFullyVisibleElementIds(),
            !visibleIds.isEmpty
        else {
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
            debugLog(
                "[MOM] ERROR: handleSeekEvent - fragment '\(anchor)' not found in section \(sectionIndex) (\(section.id))"
            )
            debugLog(
                "[MOM]   Available fragments in section: \(section.mediaOverlay.map { $0.textId }.prefix(10).joined(separator: ", "))"
            )
            return
        }

        debugLog("[MOM] handleSeekEvent - fragment found, seeking to \(section.id)#\(anchor)")

        let wasPlaying = isPlaying

        let success = await SMILPlayerActor.shared.seekToFragment(
            sectionIndex: sectionIndex,
            textId: anchor
        )
        if success {
            debugLog("[MOM] handleSeekEvent - seek successful")
            await sendHighlightCommand(sectionIndex: sectionIndex, textId: anchor)

            if wasPlaying {
                debugLog("[MOM] handleSeekEvent - resuming playback")
                try? await SMILPlayerActor.shared.play()
            }
        } else {
            debugLog("[MOM] handleSeekEvent - seek failed")
        }
    }

    func togglePlaying() async {
        if isPlaying {
            await stopPlaying()
        } else {
            await startPlaying()
        }
    }

    func startPlaying() async {
        guard !isPlaying else {
            debugLog("[MOM] startPlaying() - already playing, ignoring")
            return
        }

        debugLog("[MOM] startPlaying()")
        enableScreenWakeLock()

        do {
            let loadedBookId = await SMILPlayerActor.shared.getLoadedBookId()
            if loadedBookId != bookId {
                debugLog(
                    "[MOM] Actor has different book (\(loadedBookId ?? "none")), reloading \(bookId)"
                )
                await reloadBookIntoActor()
            }

            try await SMILPlayerActor.shared.play()
            isPlaying = true

            if let entry = await SMILPlayerActor.shared.getCurrentEntry() {
                let (currentSectionIndex, _) = await SMILPlayerActor.shared.getCurrentPosition()
                await sendHighlightCommand(
                    sectionIndex: currentSectionIndex,
                    textId: entry.textId,
                    seekToLocation: true
                )
            }
            debugLog("[MOM] startPlaying() - started")
        } catch {
            debugLog("[MOM] startPlaying() - failed: \(error)")
            disableScreenWakeLock()
        }
    }

    func stopPlaying() async {
        guard isPlaying else {
            debugLog("[MOM] stopPlaying() - already stopped, ignoring")
            return
        }

        debugLog("[MOM] stopPlaying()")
        disableScreenWakeLock()
        await SMILPlayerActor.shared.pause()
        isPlaying = false
        pageFlipTimer?.invalidate()
        pageFlipTimer = nil
        debugLog("[MOM] stopPlaying() - paused")
    }

    // MARK: - External Event Handlers (no longer needed - actor handles remote commands)
    // These are kept for backward compatibility but can be removed once fully migrated

    func nextSentence() {
        guard hasMediaOverlay else {
            debugLog("[MOM] nextSentence() - no media overlay available")
            return
        }

        let sectionIndex = cachedSectionIndex
        let entryIndex = cachedEntryIndex

        guard let section = getSection(at: sectionIndex) else {
            debugLog("[MOM] nextSentence() - invalid section")
            return
        }

        let nextEntryIndex = entryIndex + 1
        if nextEntryIndex < section.mediaOverlay.count {
            let entry = section.mediaOverlay[nextEntryIndex]
            debugLog(
                "[MOM] nextSentence() - advancing to entry \(nextEntryIndex) in section \(sectionIndex)"
            )
            Task {
                let wasPlaying = isPlaying
                _ = await SMILPlayerActor.shared.seekToFragment(
                    sectionIndex: sectionIndex,
                    textId: entry.textId
                )
                await sendHighlightCommand(
                    sectionIndex: sectionIndex,
                    textId: entry.textId,
                    seekToLocation: true
                )
                if wasPlaying { try? await SMILPlayerActor.shared.play() }
            }
        } else {
            for nextSectionIndex in (sectionIndex + 1)..<bookStructure.count {
                let nextSection = bookStructure[nextSectionIndex]
                if !nextSection.mediaOverlay.isEmpty {
                    let entry = nextSection.mediaOverlay[0]
                    debugLog("[MOM] nextSentence() - advancing to section \(nextSectionIndex)")
                    Task {
                        let wasPlaying = isPlaying
                        _ = await SMILPlayerActor.shared.seekToFragment(
                            sectionIndex: nextSectionIndex,
                            textId: entry.textId
                        )
                        await sendHighlightCommand(
                            sectionIndex: nextSectionIndex,
                            textId: entry.textId,
                            seekToLocation: true
                        )
                        if wasPlaying { try? await SMILPlayerActor.shared.play() }
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

        let sectionIndex = cachedSectionIndex
        let entryIndex = cachedEntryIndex

        if entryIndex > 0 {
            guard let section = getSection(at: sectionIndex) else {
                debugLog("[MOM] prevSentence() - invalid section")
                return
            }
            let entry = section.mediaOverlay[entryIndex - 1]
            debugLog(
                "[MOM] prevSentence() - going to entry \(entryIndex - 1) in section \(sectionIndex)"
            )
            Task {
                let wasPlaying = isPlaying
                _ = await SMILPlayerActor.shared.seekToFragment(
                    sectionIndex: sectionIndex,
                    textId: entry.textId
                )
                await sendHighlightCommand(
                    sectionIndex: sectionIndex,
                    textId: entry.textId,
                    seekToLocation: true
                )
                if wasPlaying { try? await SMILPlayerActor.shared.play() }
            }
        } else {
            for prevSectionIndex in (0..<sectionIndex).reversed() {
                let prevSection = bookStructure[prevSectionIndex]
                if !prevSection.mediaOverlay.isEmpty {
                    let lastEntryIndex = prevSection.mediaOverlay.count - 1
                    let entry = prevSection.mediaOverlay[lastEntryIndex]
                    debugLog(
                        "[MOM] prevSentence() - going to section \(prevSectionIndex), entry \(lastEntryIndex)"
                    )
                    Task {
                        let wasPlaying = isPlaying
                        _ = await SMILPlayerActor.shared.seekToFragment(
                            sectionIndex: prevSectionIndex,
                            textId: entry.textId
                        )
                        await sendHighlightCommand(
                            sectionIndex: prevSectionIndex,
                            textId: entry.textId,
                            seekToLocation: true
                        )
                        if wasPlaying { try? await SMILPlayerActor.shared.play() }
                    }
                    return
                }
            }
            debugLog("[MOM] prevSentence() - at beginning of book")
        }
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        debugLog("[MOM] Playback rate set to: \(rate)x")
        Task {
            await SMILPlayerActor.shared.setPlaybackRate(rate)
        }
    }

    /// Set volume level for audio narration (macOS only)
    func setVolume(_ newVolume: Double) {
        let clampedVolume = max(0.0, min(1.0, newVolume))
        volume = clampedVolume
        debugLog("[MOM] Volume set to: \(Int(clampedVolume * 100))%")
        Task {
            await SMILPlayerActor.shared.setVolume(clampedVolume)
        }
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

            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] _ in
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

    func checkChapterEndForSleepTimer(message: MediaOverlayProgressMessage) {
        guard sleepTimerActive,
            sleepTimerType == .endOfChapter,
            isPlaying
        else { return }

        guard let chapterElapsed = message.chapterElapsedSeconds,
            let chapterTotal = message.chapterTotalSeconds
        else { return }

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
        disableScreenWakeLock()

        if let observerId = smilObserverId {
            await SMILPlayerActor.shared.removeStateObserver(id: observerId)
            smilObserverId = nil
        }

        if isPlaying {
            isPlaying = false
            await SMILPlayerActor.shared.pause()
        }

        try? await commsBridge?.sendJsClearHighlight()
        debugLog("[MOM] Cleanup completed")
    }

    /// Handle progress update from media overlay (called via bridge)
    func handleProgressUpdate(_ message: MediaOverlayProgressMessage) {
        chapterElapsedSeconds = message.chapterElapsedSeconds
        chapterTotalSeconds = message.chapterTotalSeconds
        bookElapsedSeconds = message.bookElapsedSeconds
        bookTotalSeconds = message.bookTotalSeconds
        currentFragment = message.currentFragment

        checkChapterEndForSleepTimer(message: message)

        debugLog(
            "[MOM] Audio progress: chapter \(message.chapterElapsedSeconds?.description ?? "nil")/\(message.chapterTotalSeconds?.description ?? "nil")s, book \(message.bookElapsedSeconds?.description ?? "nil")/\(message.bookTotalSeconds?.description ?? "nil")s, fragment: \(message.currentFragment ?? "nil")"
        )
    }

    // MARK: - Screen Wake Lock

    private func enableScreenWakeLock() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        debugLog("[MOM] Screen wake lock enabled (iOS idle timer disabled)")
        #elseif os(macOS)
        guard displaySleepActivity == nil else { return }
        displaySleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Audio narration playback"
        )
        debugLog("[MOM] Screen wake lock enabled (macOS display sleep disabled)")
        #endif
    }

    private func disableScreenWakeLock() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        debugLog("[MOM] Screen wake lock disabled (iOS idle timer enabled)")
        #elseif os(macOS)
        if let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
            debugLog("[MOM] Screen wake lock disabled (macOS display sleep enabled)")
        }
        #endif
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

    /// Find SMIL entry by audio time position in a specific section
    private func findEntryByTime(_ time: Double, in sectionIndex: Int) -> (
        entryIndex: Int, entry: SMILEntry
    )? {
        guard let section = getSection(at: sectionIndex), !section.mediaOverlay.isEmpty else {
            return nil
        }

        for (index, entry) in section.mediaOverlay.enumerated() {
            if time >= entry.begin && time < entry.end {
                return (index, entry)
            }
        }

        let lastIndex = section.mediaOverlay.count - 1
        let lastEntry = section.mediaOverlay[lastIndex]
        if time >= lastEntry.end {
            return (lastIndex, lastEntry)
        }

        return nil
    }

    /// Get the current chapter label for Now Playing display
    func currentChapterLabel() -> String {
        guard cachedSectionIndex < bookStructure.count else { return "" }
        return bookStructure[cachedSectionIndex].label ?? "Chapter \(cachedSectionIndex + 1)"
    }

    // MARK: - Highlight and Page Flip

    /// Send highlight command to JS for the current fragment
    private func sendHighlightCommand(
        sectionIndex: Int,
        textId: String,
        seekToLocation: Bool = false
    ) async {
        do {
            try await commsBridge?.sendJsHighlightFragment(
                sectionIndex: sectionIndex,
                textId: textId,
                seekToLocation: seekToLocation
            )
            debugLog(
                "[MOM] Highlight command sent: section=\(sectionIndex), textId=\(textId), seekToLocation=\(seekToLocation)"
            )
        } catch {
            debugLog("[MOM] Error sending highlight command: \(error)")
        }
    }

    /// Handle element visibility message from JS (for page flip timing)
    func handleElementVisibility(_ message: ElementVisibilityMessage) {
        pageFlipTimer?.invalidate()
        pageFlipTimer = nil

        guard isPlaying else { return }

        debugLog(
            "[MOM] Element visibility: textId=\(message.textId), visible=\(message.visibleRatio), offScreen=\(message.offScreenRatio)"
        )

        if message.offScreenRatio >= 0.9 {
            debugLog("[MOM] Element almost fully off-screen, flipping immediately")
            Task {
                await self.flipPageIfNotDebounced()
            }
        } else if message.offScreenRatio > 0 {
            Task {
                guard let entry = await SMILPlayerActor.shared.getCurrentEntry() else { return }
                let entryDuration = entry.end - entry.begin
                let earlyOffset = message.visibleRatio >= 0.98 ? 0.0 : 1.0
                let delay = max(
                    0,
                    (entryDuration * message.visibleRatio / self.playbackRate) - earlyOffset
                )

                debugLog(
                    "[MOM] Scheduling page flip in \(String(format: "%.2f", delay))s (entry duration: \(String(format: "%.2f", entryDuration))s, visible: \(String(format: "%.0f", message.visibleRatio * 100))%)"
                )

                await MainActor.run {
                    self.pageFlipTimer = Timer.scheduledTimer(
                        withTimeInterval: delay,
                        repeats: false
                    ) {
                        [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.flipPageIfNotDebounced()
                        }
                    }
                }
            }
        }
    }

    private func flipPageIfNotDebounced() async {
        guard isPlaying else { return }

        if let last = lastFlipTime, Date().timeIntervalSince(last) < 0.3 {
            debugLog("[MOM] Debouncing page flip")
            return
        }

        lastFlipTime = Date()
        debugLog("[MOM] Page flip")
        try? await commsBridge?.sendJsGoRightCommand()
    }
}
