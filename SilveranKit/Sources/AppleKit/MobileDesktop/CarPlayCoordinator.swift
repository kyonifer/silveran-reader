#if os(iOS)
import Foundation
import UIKit

public struct CarPlayChapter: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let sectionIndex: Int
    public let href: String?

    init(id: Int, label: String, sectionIndex: Int, href: String? = nil) {
        self.id = id
        self.label = label
        self.sectionIndex = sectionIndex
        self.href = href
    }
}

private enum ActivePlayer {
    case smil
    case audiobook
}

@MainActor
@Observable
public final class CarPlayCoordinator {
    public static let shared = CarPlayCoordinator()

    public var onLibraryUpdated: (() -> Void)?
    public var onChaptersUpdated: (() -> Void)?
    public var onPlaybackStateChanged: (() -> Void)?
    public var isCarPlayConnected: Bool = false
    public var isPlayerViewActive: Bool = false

    private var smilObserverId: UUID?
    private var audiobookObserverId: UUID?
    private var lmaObserverId: UUID?
    private var currentPlaybackState: SMILPlaybackState?
    private var currentAudiobookState: AudiobookPlaybackState?
    private var cachedBookStructure: [SectionInfo] = []
    private var cachedAudiobookChapters: [AudiobookSessionChapter] = []
    private var wasPlaying: Bool = false
    private var syncTimer: Timer?
    private var activePlayer: ActivePlayer?
    private var currentBookID: BookID?
    private var currentBookTitle: String?
    private var currentAudiobookHref: String?
    private var isInitialized = false
    private var isPositionRestored = false

    private init() {
        Task {
            await observeSMILPlayerActor()
            await observeLocalMediaActor()
            await ensureLocalMediaScanned()
            isInitialized = true
        }
    }

    private func ensureLocalMediaScanned() async {
        do {
            try await BookServiceActor.shared.scanLibraryCache()
            debugLog("[CarPlayCoordinator] Local media scan complete")
        } catch {
            debugLog("[CarPlayCoordinator] Failed to scan local media: \(error)")
        }
    }

    private func observeLocalMediaActor() async {
        lmaObserverId = await BookServiceActor.shared.addLibraryCacheObserver { [weak self] in
            Task { @MainActor [weak self] in
                debugLog("[CarPlayCoordinator] Library updated, notifying CarPlay")
                self?.onLibraryUpdated?()
            }
        }
    }

    private func observeSMILPlayerActor() async {
        smilObserverId = await SMILPlayerActor.shared.addStateObserver {
            @MainActor [weak self] state in
            guard let self else { return }

            let previousBookID = self.currentPlaybackState?.bookID
            let previouslyPlaying = self.currentPlaybackState?.isPlaying ?? false

            debugLog(
                "[CarPlayCoordinator] State update: bookID=\(state.bookID?.description ?? "nil"), isPlaying=\(state.isPlaying), prev=\(previouslyPlaying)"
            )
            self.currentPlaybackState = state

            if let bookID = state.bookID {
                if previousBookID != bookID {
                    debugLog("[CarPlayCoordinator] SMIL book changed: \(bookID)")
                    self.currentBookID = bookID
                    self.activePlayer = .smil
                    Task {
                        await self.refreshBookStructure()
                    }
                }

                if previouslyPlaying && !state.isPlaying {
                    debugLog("[CarPlayCoordinator] SMIL playback paused, syncing progress")
                    Task { @MainActor in
                        await self.syncProgress(reason: .userPausedPlayback)
                    }
                    self.stopPeriodicSync()
                } else if !previouslyPlaying && state.isPlaying {
                    debugLog("[CarPlayCoordinator] SMIL playback started, starting periodic sync")
                    Task { @MainActor in
                        await self.startPeriodicSync()
                    }
                }
            } else if previousBookID != nil {
                debugLog("[CarPlayCoordinator] SMIL book unloaded")
                self.currentBookID = nil
                self.activePlayer = nil
                self.currentAudiobookHref = nil
                self.isPositionRestored = false
                self.stopPeriodicSync()
            }

            self.onPlaybackStateChanged?()
        }
        debugLog(
            "[CarPlayCoordinator] SMILPlayerActor observer registered: \(smilObserverId?.uuidString ?? "nil")"
        )
    }

    private func handleAudiobookStateChange(_ state: AudiobookPlaybackState) {
        guard activePlayer == .audiobook else { return }

        currentAudiobookState = state
        wasPlaying = state.isPlaying

        // Audiobook progress syncing is owned by AudioSessionActor.
        onPlaybackStateChanged?()
    }

    private func refreshBookStructure() async {
        cachedBookStructure = await SMILPlayerActor.shared.getBookStructure()
        onChaptersUpdated?()
    }

    // MARK: - Public API for CarPlay

    public func getDownloadedBooks(category: LocalMediaCategory) async -> [BookMetadata] {
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)

        var result: [BookMetadata] = []
        for book in snapshot.books {
            guard let paths = snapshot.mediaPaths[book.id] else { continue }
            let hasCategory =
                switch category {
                    case .ebook:
                        paths.ebookPath != nil
                    case .audio:
                        paths.audioPath != nil
                    case .synced:
                        paths.syncedPath != nil
                }

            if hasCategory {
                // If requesting audiobooks, skip books that also have readaloud (prefer readaloud)
                if category == .audio && paths.syncedPath != nil {
                    continue
                }
                result.append(book)
            }
        }

        return result.sorted { ($0.position?.updatedAt ?? "") > ($1.position?.updatedAt ?? "") }
    }

    public func getCoverImage(for bookId: BookID) async -> UIImage? {
        guard let data = await getCoverImageData(for: bookId) else { return nil }
        return UIImage(data: data)
    }

    private func getCoverImageData(for bookId: BookID) async -> Data? {
        // Try audioSquare first (preferred for CarPlay - square covers)
        if let data = await BookServiceActor.shared.cachedCoverData(for: bookId, audio: true) {
            return data
        }
        // Fall back to standard cover
        if let data = await BookServiceActor.shared.cachedCoverData(for: bookId, audio: false) {
            return data
        }
        // Last resort: extract from local file (for standalone imports)
        return nil
    }

    public var chapters: [CarPlayChapter] {
        switch activePlayer {
            case .audiobook:
                return cachedAudiobookChapters.enumerated().map { idx, chapter in
                    CarPlayChapter(
                        id: idx,
                        label: chapter.title,
                        sectionIndex: idx,
                        href: chapter.id,
                    )
                }
            case .smil, .none:
                return
                    cachedBookStructure
                    .filter { !$0.mediaOverlay.isEmpty }
                    .enumerated()
                    .map { idx, section in
                        CarPlayChapter(
                            id: idx,
                            label: section.label ?? "Chapter \(idx + 1)",
                            sectionIndex: section.index,
                        )
                    }
        }
    }

    public var currentChapterSectionIndex: Int? {
        switch activePlayer {
            case .audiobook:
                return currentAudiobookState?.currentChapterIndex
            case .smil, .none:
                return currentPlaybackState?.currentSectionIndex
        }
    }

    public func selectChapter(sectionIndex: Int) {
        debugLog("[CarPlayCoordinator] selectChapter: sectionIndex=\(sectionIndex)")
        Task {
            let wasPlaying = isPlaying

            switch activePlayer {
                case .audiobook:
                    guard sectionIndex < cachedAudiobookChapters.count else { return }
                    let chapter = cachedAudiobookChapters[sectionIndex]
                    await AudiobookActor.shared.seekToChapter(href: chapter.id)
                    if wasPlaying {
                        try? await AudiobookActor.shared.play()
                    }
                case .smil, .none:
                    do {
                        try await SMILPlayerActor.shared.seekToEntry(
                            sectionIndex: sectionIndex,
                            entryIndex: 0,
                        )
                        if wasPlaying {
                            try? await SMILPlayerActor.shared.play()
                        }
                    } catch {
                        debugLog("[CarPlayCoordinator] Failed to seek to chapter: \(error)")
                    }
            }
        }
    }

    public func loadAndPlayBook(_ metadata: BookMetadata, category: LocalMediaCategory) async throws
    {
        debugLog("[CarPlayCoordinator] loadAndPlayBook: \(metadata.title), category: \(category)")

        guard
            let localMedia = await BookServiceActor.shared.resolveLocalMedia(
                for: metadata.id,
                category: category,
            )
        else {
            debugLog("[CarPlayCoordinator] No local path for book \(metadata.uuid)")
            throw CarPlayError.noLocalPath
        }
        debugLog("[CarPlayCoordinator] Found local path: \(localMedia.url)")

        if category == .audio {
            try await loadM4BAudiobook(metadata: metadata, localPath: localMedia.url)
        } else {
            try await loadSMILBook(metadata: metadata)
        }
    }

    public enum CarPlayError: Error {
        case noLocalPath
    }

    private func loadM4BAudiobook(metadata: BookMetadata, localPath: URL) async throws {
        debugLog(
            "[CarPlayCoordinator] loadM4BAudiobook start: carPlayConnected=\(isCarPlayConnected), playerViewActive=\(isPlayerViewActive)"
        )
        activePlayer = .audiobook
        currentBookID = metadata.id
        currentBookTitle = metadata.title
        currentAudiobookHref = nil
        wasPlaying = false

        if audiobookObserverId == nil {
            audiobookObserverId = await AudiobookActor.shared.addStateObserver {
                [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleAudiobookStateChange(state)
                }
            }
            debugLog(
                "[CarPlayCoordinator] Audiobook observer registered: \(String(describing: audiobookObserverId))"
            )
        }

        try await AudioSessionActor.shared.openAudiobook(book: metadata, mediaURL: localPath)

        cachedAudiobookChapters = (await AudioSessionActor.shared.currentState())?.chapters ?? []
        onChaptersUpdated?()

        isPositionRestored = true

        debugLog("[CarPlayCoordinator] M4B audiobook opened via AudioSessionActor, starting playback")
        try await AudioSessionActor.shared.transport(.play)
    }

    private func loadSMILBook(metadata: BookMetadata) async throws {
        debugLog(
            "[CarPlayCoordinator] loadSMILBook start: carPlayConnected=\(isCarPlayConnected), playerViewActive=\(isPlayerViewActive)"
        )
        await AudioSessionActor.shared.closeAudiobookArmIfActive()
        activePlayer = .smil
        currentBookID = metadata.id
        currentBookTitle = metadata.title
        currentAudiobookHref = nil
        wasPlaying = false

        let preparedMedia = try await BookServiceActor.shared.prepareEbookForReading(
            bookID: metadata.id,
            category: .synced,
        )

        try await SMILPlayerActor.shared.loadBook(
            epubPath: preparedMedia.originalURL,
            bookID: metadata.id,
            title: metadata.title,
            author: metadata.authors?.first?.name,
        )

        await refreshBookStructure()

        if let coverData = await getCoverImageData(for: metadata.id) {
            await SMILPlayerActor.shared.setCoverImage(coverData)
        }

        isPositionRestored = false

        var locatorToUse: BookLocator? = nil
        if let psaProgress = await ProgressSyncActor.shared.getBookProgress(for: metadata.id),
            let psaLocator = psaProgress.locator
        {
            debugLog(
                "[CarPlayCoordinator] Got SMIL position from PSA (source: \(psaProgress.source))"
            )
            locatorToUse = psaLocator
        } else if let metadataLocator = metadata.position?.locator {
            debugLog("[CarPlayCoordinator] Using fallback SMIL position from metadata")
            locatorToUse = metadataLocator
        }

        if let locator = locatorToUse {
            let bookStructure = await SMILPlayerActor.shared.getBookStructure()
            if let sectionIndex = findSectionIndex(for: locator.href, in: bookStructure),
                let fragment = locator.locations?.fragments?.first
            {
                let success = await SMILPlayerActor.shared.seekToFragment(
                    sectionIndex: sectionIndex,
                    textId: fragment,
                )
                if success {
                    debugLog(
                        "[CarPlayCoordinator] Restored SMIL position to section \(sectionIndex), fragment: \(fragment)"
                    )
                }
            } else if let totalProg = locator.locations?.totalProgression, totalProg > 0 {
                let success = await SMILPlayerActor.shared.seekToTotalProgression(totalProg)
                debugLog(
                    "[CarPlayCoordinator] Restored SMIL position using totalProgression \(totalProg): \(success ? "success" : "failed")"
                )
            } else {
                debugLog(
                    "[CarPlayCoordinator] No usable SMIL position data, starting from beginning"
                )
            }
        } else {
            debugLog("[CarPlayCoordinator] No saved SMIL position, starting from beginning")
        }

        isPositionRestored = true

        let playbackSpeed = await SettingsActor.shared.config.playback.defaultPlaybackSpeed
        await SMILPlayerActor.shared.setPlaybackRate(playbackSpeed)
        debugLog("[CarPlayCoordinator] SMIL book loaded at \(playbackSpeed)x, starting playback")
        try await SMILPlayerActor.shared.play()
    }

    public var isPlaying: Bool {
        switch activePlayer {
            case .audiobook:
                return currentAudiobookState?.isPlaying ?? false
            case .smil, .none:
                return currentPlaybackState?.isPlaying ?? false
        }
    }

    public var activeBookId: BookID? {
        currentBookID
    }

    public var activeCategory: LocalMediaCategory? {
        switch activePlayer {
            case .audiobook:
                return .audio
            case .smil:
                return .synced
            case .none:
                return nil
        }
    }

    public func isBookCurrentlyLoaded(_ bookID: BookID) -> Bool {
        activeBookId == bookID
    }

    public func isBookCurrentlyPlaying(_ bookID: BookID) -> Bool {
        activeBookId == bookID && isPlaying
    }

    public var currentPlaybackRate: Double {
        switch activePlayer {
            case .audiobook:
                return Double(currentAudiobookState?.playbackRate ?? 1.0)
            case .smil, .none:
                return currentPlaybackState?.playbackRate ?? 1.0
        }
    }

    public func setPlaybackRate(_ rate: Double) async {
        switch activePlayer {
            case .audiobook:
                await AudiobookActor.shared.setPlaybackRate(rate)
            case .smil:
                await SMILPlayerActor.shared.setPlaybackRate(rate)
            case .none:
                break
        }
        try? await SettingsActor.shared.updateConfig(defaultPlaybackSpeed: rate)
        debugLog("[CarPlayCoordinator] Playback rate set to \(rate)x")
    }

    // MARK: - Progress Sync

    private func startPeriodicSync() async {
        guard isCarPlayConnected else {
            debugLog("[CarPlayCoordinator] Not starting periodic sync: CarPlay not connected")
            return
        }

        stopPeriodicSync()

        let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
        debugLog("[CarPlayCoordinator] Starting periodic sync with interval \(syncInterval)s")

        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                await self?.syncProgress(reason: .periodicDuringActivePlayback)
            }
        }
    }

    private func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func syncProgress(reason: SyncReason) async {
        guard isCarPlayConnected else {
            debugLog("[CarPlayCoordinator] Cannot sync: CarPlay not connected")
            return
        }

        guard let bookID = currentBookID else {
            debugLog("[CarPlayCoordinator] Cannot sync: no book identity")
            return
        }

        // If phone player is active, let it handle syncing to avoid duplicates
        if isPlayerViewActive {
            debugLog(
                "[CarPlayCoordinator] Skipping sync: phone player view is active, it will handle syncing"
            )
            return
        }

        guard isPositionRestored else {
            debugLog("[CarPlayCoordinator] Skipping sync: position not yet restored")
            return
        }

        let locator: BookLocator
        let timestampMs = floor(Date().timeIntervalSince1970 * 1000)
        let sourceIdentifier: String
        let locationDescription: String

        switch activePlayer {
            case .audiobook:
                debugLog("[CarPlayCoordinator] Audiobook sync is handled by AudioSessionActor")
                return

            case .smil, .none:
                guard let state = currentPlaybackState else {
                    debugLog("[CarPlayCoordinator] Cannot sync SMIL: no playback state")
                    return
                }

                guard state.currentSectionIndex < cachedBookStructure.count else {
                    debugLog("[CarPlayCoordinator] Cannot sync: section index out of bounds")
                    return
                }

                let section = cachedBookStructure[state.currentSectionIndex]
                let href = section.id

                let fragment: String?
                if state.currentEntryIndex < section.mediaOverlay.count {
                    fragment = section.mediaOverlay[state.currentEntryIndex].textId
                } else {
                    fragment = nil
                }

                let totalProgression = state.bookTotal > 0 ? state.bookElapsed / state.bookTotal : 0

                let locations = BookLocator.Locations(
                    fragments: fragment.map { [$0] },
                    progression: nil,
                    position: nil,
                    totalProgression: totalProgression,
                    cssSelector: nil,
                    partialCfi: nil,
                    domRange: nil,
                )

                locator = BookLocator(
                    href: href,
                    type: "application/xhtml+xml",
                    title: state.chapterLabel,
                    locations: locations,
                    text: nil,
                )

                sourceIdentifier = "CarPlay · Readaloud"
                let chapterLabel = state.chapterLabel ?? "Section \(state.currentSectionIndex + 1)"
                let sectionProgress =
                    section.mediaOverlay.count > 0
                    ? Double(state.currentEntryIndex) / Double(section.mediaOverlay.count)
                    : 0
                locationDescription = "\(chapterLabel), \(Int(sectionProgress * 100))%"

                debugLog(
                    "[CarPlayCoordinator] Syncing SMIL progress: book=\(bookID), href=\(href), fragment=\(fragment ?? "none"), reason=\(reason)"
                )
        }

        // Don't sync 0% positions - these are usually loading states that would reset progress
        if let totalProg = locator.locations?.totalProgression, totalProg < 0.001 {
            debugLog("[CarPlayCoordinator] Skipping sync: 0% position would reset progress")
            return
        }

        let result = await ProgressSyncActor.shared.syncProgress(
            bookID: bookID,
            locator: locator,
            timestamp: timestampMs,
            reason: reason,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
        )

        debugLog("[CarPlayCoordinator] Sync result: \(result)")
    }
}
#endif
