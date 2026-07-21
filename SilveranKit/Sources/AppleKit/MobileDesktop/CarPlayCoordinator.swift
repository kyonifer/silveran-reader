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

    private var smilObserverId: UUID?
    private var audiobookObserverId: UUID?
    private var lmaObserverId: UUID?
    private var currentPlaybackState: SMILPlaybackState?
    private var currentAudiobookState: AudiobookPlaybackState?
    private var cachedBookStructure: [SectionInfo] = []
    private var cachedAudiobookChapters: [AudiobookSessionChapter] = []
    private var wasPlaying: Bool = false
    private var activePlayer: ActivePlayer?
    private var currentBookID: BookID?
    private var currentBookTitle: String?
    private var currentAudiobookHref: String?
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

                // SMIL progress syncing is owned by the ReadingSession.
            } else if previousBookID != nil {
                debugLog("[CarPlayCoordinator] SMIL book unloaded")
                self.currentBookID = nil
                self.activePlayer = nil
                self.currentAudiobookHref = nil
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
            "[CarPlayCoordinator] loadM4BAudiobook start: carPlayConnected=\(isCarPlayConnected)"
        )
        if activePlayer == .smil, let previousID = currentBookID {
            // The audiobook takes over the audio engine; a headless readaloud
            // session has no owner left to close it, so end it here.
            await ReadingSessionStore.shared.endIfViewDetached(for: previousID)
        }
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

        debugLog(
            "[CarPlayCoordinator] M4B audiobook opened via AudioSessionActor, starting playback"
        )
        try await AudioSessionActor.shared.transport(.play)
    }

    private func loadSMILBook(metadata: BookMetadata) async throws {
        debugLog(
            "[CarPlayCoordinator] loadSMILBook start: carPlayConnected=\(isCarPlayConnected)"
        )
        activePlayer = .smil
        currentBookID = metadata.id
        currentBookTitle = metadata.title
        currentAudiobookHref = nil
        wasPlaying = false

        let session = ReadingSessionStore.shared.obtain(
            metadata: metadata,
            category: .synced,
            localMediaPath: nil,
            settings: nil,
        )
        session.prepare()
        await session.awaitPreparation()
        if let error = session.lastPrepareError {
            throw error
        }

        await refreshBookStructure()

        if let coverData = await getCoverImageData(for: metadata.id) {
            await SMILPlayerActor.shared.setCoverImage(coverData)
        }

        await session.restoreEnginePositionFromSavedProgress()

        debugLog("[CarPlayCoordinator] SMIL book loaded, starting playback")
        try await AudioSessionActor.shared.transport(.play)
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

}
#endif
