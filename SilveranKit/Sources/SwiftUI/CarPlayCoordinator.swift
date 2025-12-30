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
    private var cachedAudiobookChapters: [AudiobookChapter] = []
    private var wasPlaying: Bool = false
    private var syncTimer: Timer?
    private var activePlayer: ActivePlayer?
    private var currentBookId: String?
    private var currentBookTitle: String?
    private var isInitialized = false

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
            try await LocalMediaActor.shared.scanForMedia()
            debugLog("[CarPlayCoordinator] Local media scan complete")
        } catch {
            debugLog("[CarPlayCoordinator] Failed to scan local media: \(error)")
        }
    }

    private func observeLocalMediaActor() async {
        lmaObserverId = await LocalMediaActor.shared.addObserver { @MainActor [weak self] in
            debugLog("[CarPlayCoordinator] Library updated, notifying CarPlay")
            self?.onLibraryUpdated?()
        }
    }

    private func observeSMILPlayerActor() async {
        smilObserverId = await SMILPlayerActor.shared.addStateObserver {
            @MainActor [weak self] state in
            guard let self else { return }

            let previousBookId = self.currentPlaybackState?.bookId
            let previouslyPlaying = self.currentPlaybackState?.isPlaying ?? false

            debugLog(
                "[CarPlayCoordinator] State update: bookId=\(state.bookId ?? "nil"), isPlaying=\(state.isPlaying), prev=\(previouslyPlaying)"
            )
            self.currentPlaybackState = state

            if let bookId = state.bookId {
                if previousBookId != bookId {
                    debugLog("[CarPlayCoordinator] SMIL book changed: \(bookId)")
                    self.currentBookId = bookId
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
            } else if previousBookId != nil {
                debugLog("[CarPlayCoordinator] SMIL book unloaded")
                self.currentBookId = nil
                self.activePlayer = nil
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

        let previouslyPlaying = wasPlaying
        currentAudiobookState = state
        wasPlaying = state.isPlaying

        debugLog(
            "[CarPlayCoordinator] Audiobook state: isPlaying=\(state.isPlaying), wasPlaying=\(previouslyPlaying)"
        )

        if previouslyPlaying && !state.isPlaying {
            debugLog("[CarPlayCoordinator] Audiobook paused, syncing progress")
            Task { @MainActor in
                await self.syncProgress(reason: .userPausedPlayback)
            }
            stopPeriodicSync()
        } else if !previouslyPlaying && state.isPlaying {
            debugLog("[CarPlayCoordinator] Audiobook started, starting periodic sync")
            Task { @MainActor in
                await self.startPeriodicSync()
            }
        }

        onPlaybackStateChanged?()
    }

    private func refreshBookStructure() async {
        cachedBookStructure = await SMILPlayerActor.shared.getBookStructure()
        onChaptersUpdated?()
    }

    // MARK: - Public API for CarPlay

    public func getDownloadedBooks(category: LocalMediaCategory) async -> [BookMetadata] {
        let storytellerMeta = await LocalMediaActor.shared.localStorytellerMetadata
        let standaloneMeta = await LocalMediaActor.shared.localStandaloneMetadata
        let allMetadata = storytellerMeta + standaloneMeta

        var result: [BookMetadata] = []
        for book in allMetadata {
            let downloaded = await LocalMediaActor.shared.downloadedCategories(for: book.uuid)
            if downloaded.contains(category) {
                result.append(book)
            }
        }

        return result.sorted { ($0.position?.updatedAt ?? "") > ($1.position?.updatedAt ?? "") }
    }

    public func getCoverImage(for bookId: String) async -> UIImage? {
        // Try audioSquare first (preferred for CarPlay - square covers)
        if let data = await FilesystemActor.shared.loadCoverImage(
            uuid: bookId,
            variant: "audioSquare"
        ) {
            return UIImage(data: data)
        }
        // Fall back to standard cover
        if let data = await FilesystemActor.shared.loadCoverImage(uuid: bookId, variant: "standard")
        {
            return UIImage(data: data)
        }
        // Last resort: extract from local file (for standalone imports)
        if let data = await LocalMediaActor.shared.extractLocalCover(for: bookId) {
            return UIImage(data: data)
        }
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
                        href: chapter.href
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
                            sectionIndex: section.index
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
            switch activePlayer {
                case .audiobook:
                    guard sectionIndex < cachedAudiobookChapters.count else { return }
                    let chapter = cachedAudiobookChapters[sectionIndex]
                    await AudiobookActor.shared.seekToChapter(href: chapter.href)
                case .smil, .none:
                    do {
                        try await SMILPlayerActor.shared.seekToEntry(
                            sectionIndex: sectionIndex,
                            entryIndex: 0
                        )
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
            let localPath = await LocalMediaActor.shared.mediaFilePath(
                for: metadata.uuid,
                category: category
            )
        else {
            debugLog("[CarPlayCoordinator] No local path for book \(metadata.uuid)")
            throw CarPlayError.noLocalPath
        }
        debugLog("[CarPlayCoordinator] Found local path: \(localPath)")

        if category == .audio {
            try await loadM4BAudiobook(metadata: metadata, localPath: localPath)
        } else {
            try await loadSMILBook(metadata: metadata, localPath: localPath)
        }
    }

    public enum CarPlayError: Error {
        case noLocalPath
    }

    private func loadM4BAudiobook(metadata: BookMetadata, localPath: URL) async throws {
        await SMILPlayerActor.shared.cleanup()
        activePlayer = .audiobook
        currentBookId = metadata.uuid
        currentBookTitle = metadata.title
        wasPlaying = false

        audiobookObserverId = await AudiobookActor.shared.addStateObserver {
            @MainActor [weak self] state in
            self?.handleAudiobookStateChange(state)
        }
        debugLog(
            "[CarPlayCoordinator] Audiobook observer registered: \(String(describing: audiobookObserverId))"
        )

        let audiobookMetadata = try await AudiobookActor.shared.validateAndLoadAudiobook(
            url: localPath
        )
        cachedAudiobookChapters = audiobookMetadata.chapters
        onChaptersUpdated?()

        try await AudiobookActor.shared.preparePlayer()

        if let image = await getCoverImage(for: metadata.id) {
            await AudiobookActor.shared.setCoverImage(image)
        }

        if let locator = metadata.position?.locator,
            let totalProg = locator.locations?.totalProgression, totalProg > 0
        {
            debugLog("[CarPlayCoordinator] Restoring audiobook position to \(totalProg * 100)%")
            await AudiobookActor.shared.seekToTotalProgressFraction(totalProg)
        }

        debugLog("[CarPlayCoordinator] M4B audiobook loaded, starting playback immediately")
        try await AudiobookActor.shared.play()
    }

    private func loadSMILBook(metadata: BookMetadata, localPath: URL) async throws {
        await AudiobookActor.shared.cleanup()
        activePlayer = .smil
        currentBookId = metadata.uuid
        currentBookTitle = metadata.title
        wasPlaying = false

        _ = try await FilesystemActor.shared.extractEpubIfNeeded(
            epubPath: localPath,
            forceExtract: true
        )

        try await SMILPlayerActor.shared.loadBook(
            epubPath: localPath,
            bookId: metadata.uuid,
            title: metadata.title,
            author: metadata.authors?.first?.name
        )

        await refreshBookStructure()

        if let image = await getCoverImage(for: metadata.id) {
            await SMILPlayerActor.shared.setCoverImage(image)
        }

        if let locator = metadata.position?.locator {
            let bookStructure = await SMILPlayerActor.shared.getBookStructure()
            if let sectionIndex = findSectionIndex(for: locator.href, in: bookStructure),
                let fragment = locator.locations?.fragments?.first
            {
                let success = await SMILPlayerActor.shared.seekToFragment(
                    sectionIndex: sectionIndex,
                    textId: fragment
                )
                if success {
                    debugLog(
                        "[CarPlayCoordinator] Restored position to section \(sectionIndex), fragment: \(fragment)"
                    )
                }
            } else if let totalProg = locator.locations?.totalProgression, totalProg > 0 {
                let success = await SMILPlayerActor.shared.seekToTotalProgression(totalProg)
                debugLog(
                    "[CarPlayCoordinator] Restored position using totalProgression \(totalProg): \(success ? "success" : "failed")"
                )
            }
        }

        debugLog("[CarPlayCoordinator] SMIL book loaded, starting playback immediately")
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

    public var activeBookId: String? {
        currentBookId
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

    public func isBookCurrentlyLoaded(_ bookId: String) -> Bool {
        currentBookId == bookId
    }

    public func isBookCurrentlyPlaying(_ bookId: String) -> Bool {
        currentBookId == bookId && isPlaying
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

        guard let bookId = currentBookId else {
            debugLog("[CarPlayCoordinator] Cannot sync: no bookId")
            return
        }

        // If phone player is active, let it handle syncing to avoid duplicates
        if isPlayerViewActive {
            debugLog("[CarPlayCoordinator] Skipping sync: phone player view is active, it will handle syncing")
            return
        }

        let locator: BookLocator
        let timestampMs = Date().timeIntervalSince1970 * 1000
        let sourceIdentifier: String
        let locationDescription: String

        switch activePlayer {
            case .audiobook:
                guard let state = currentAudiobookState else {
                    debugLog("[CarPlayCoordinator] Cannot sync audiobook: no playback state")
                    return
                }

                let chapterIndex = state.currentChapterIndex ?? 0
                let chapter =
                    chapterIndex < cachedAudiobookChapters.count
                    ? cachedAudiobookChapters[chapterIndex]
                    : nil

                let totalProgression = state.duration > 0 ? state.currentTime / state.duration : 0

                let locations = BookLocator.Locations(
                    fragments: nil,
                    progression: nil,
                    position: nil,
                    totalProgression: totalProgression,
                    cssSelector: nil,
                    partialCfi: nil,
                    domRange: nil
                )

                locator = BookLocator(
                    href: chapter?.href ?? "chapter-\(chapterIndex)",
                    type: "audio/mp4",
                    title: chapter?.title ?? "Chapter \(chapterIndex + 1)",
                    locations: locations,
                    text: nil
                )

                sourceIdentifier = "CarPlay/Audiobook"
                let chapterTitle = chapter?.title ?? "Chapter \(chapterIndex + 1)"
                locationDescription = "\(chapterTitle), \(Int(totalProgression * 100))%"

                debugLog(
                    "[CarPlayCoordinator] Syncing audiobook progress: book=\(bookId), chapter=\(chapterIndex), progress=\(totalProgression), reason=\(reason)"
                )

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
                    domRange: nil
                )

                locator = BookLocator(
                    href: href,
                    type: "application/xhtml+xml",
                    title: state.chapterLabel,
                    locations: locations,
                    text: nil
                )

                sourceIdentifier = "CarPlay/Readaloud"
                let chapterLabel = state.chapterLabel ?? "Section \(state.currentSectionIndex + 1)"
                locationDescription = "\(chapterLabel), \(Int(totalProgression * 100))%"

                debugLog(
                    "[CarPlayCoordinator] Syncing SMIL progress: book=\(bookId), href=\(href), fragment=\(fragment ?? "none"), reason=\(reason)"
                )
        }

        // Don't sync 0% positions - these are usually loading states that would reset progress
        if let totalProg = locator.locations?.totalProgression, totalProg < 0.001 {
            debugLog("[CarPlayCoordinator] Skipping sync: 0% position would reset progress")
            return
        }

        let result = await ProgressSyncActor.shared.syncProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestampMs,
            reason: reason,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription
        )

        debugLog("[CarPlayCoordinator] Sync result: \(result)")
    }
}
#endif
