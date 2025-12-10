#if os(iOS)
import Foundation
import UIKit

public struct CarPlayChapter: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let sectionIndex: Int
}

@MainActor
public final class CarPlayCoordinator {
    public static let shared = CarPlayCoordinator()

    public weak var mediaViewModel: MediaViewModel? {
        didSet {
            if mediaViewModel != nil {
                onMediaViewModelReady?()
            }
        }
    }

    public var onMediaViewModelReady: (() -> Void)?
    public var onLibraryUpdated: (() -> Void)?
    public var onChaptersUpdated: (() -> Void)?
    public var onPlaybackStateChanged: (() -> Void)?

    private var smilObserverId: UUID?
    private var lmaObserverId: UUID?
    private var currentPlaybackState: SMILPlaybackState?
    private var cachedBookStructure: [SectionInfo] = []
    private var wasPlaying: Bool = false
    private var syncTimer: Timer?

    private init() {
        Task {
            await observeSMILPlayerActor()
            await observeLocalMediaActor()
        }
    }

    private func observeLocalMediaActor() async {
        lmaObserverId = await LocalMediaActor.shared.addObserver { @MainActor [weak self] in
            debugLog("[CarPlayCoordinator] Library updated, notifying CarPlay")
            self?.onLibraryUpdated?()
        }
    }

    private func observeSMILPlayerActor() async {
        smilObserverId = await SMILPlayerActor.shared.addStateObserver { @MainActor [weak self] state in
            guard let self else { return }
            let previousBookId = self.currentPlaybackState?.bookId
            let previouslyPlaying = self.wasPlaying

            self.currentPlaybackState = state
            self.wasPlaying = state.isPlaying

            if state.bookId != previousBookId {
                Task { @MainActor in
                    await self.refreshBookStructure()
                }
            }

            if previouslyPlaying && !state.isPlaying {
                debugLog("[CarPlayCoordinator] Playback paused, syncing progress")
                Task { @MainActor in
                    await self.syncProgress(reason: .userPausedPlayback)
                }
                self.stopPeriodicSync()
            } else if !previouslyPlaying && state.isPlaying {
                debugLog("[CarPlayCoordinator] Playback started, starting periodic sync")
                Task { @MainActor in
                    await self.startPeriodicSync()
                }
            }

            self.onPlaybackStateChanged?()
        }
    }

    private func refreshBookStructure() async {
        cachedBookStructure = await SMILPlayerActor.shared.getBookStructure()
        onChaptersUpdated?()
    }

    public var chapters: [CarPlayChapter] {
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

    public var currentChapterSectionIndex: Int? {
        currentPlaybackState?.currentSectionIndex
    }

    public func selectChapter(sectionIndex: Int) {
        debugLog("[CarPlayCoordinator] selectChapter: sectionIndex=\(sectionIndex)")
        Task {
            do {
                try await SMILPlayerActor.shared.seekToEntry(sectionIndex: sectionIndex, entryIndex: 0)
            } catch {
                debugLog("[CarPlayCoordinator] Failed to seek to chapter: \(error)")
            }
        }
    }

    public func loadAndPlayBook(_ metadata: BookMetadata, category: LocalMediaCategory) {
        debugLog("[CarPlayCoordinator] loadAndPlayBook: \(metadata.title), category: \(category)")

        guard let mediaViewModel = mediaViewModel else {
            debugLog("[CarPlayCoordinator] No mediaViewModel available")
            return
        }

        guard let localPath = mediaViewModel.localMediaPath(for: metadata.id, category: category) else {
            debugLog("[CarPlayCoordinator] No local path for book")
            return
        }

        Task {
            do {
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

                let coverData = mediaViewModel.library.audiobookCoverCache[metadata.id].flatMap { $0?.data }
                    ?? mediaViewModel.library.ebookCoverCache[metadata.id].flatMap { $0?.data }
                if let data = coverData, let image = UIImage(data: data) {
                    await SMILPlayerActor.shared.setCoverImage(image)
                }

                let freshMetadata = mediaViewModel.library.bookMetaData.first { $0.uuid == metadata.uuid }
                if let locator = freshMetadata?.position?.locator {
                    let bookStructure = await SMILPlayerActor.shared.getBookStructure()
                    if let sectionIndex = bookStructure.firstIndex(where: { $0.id == locator.href }),
                       let fragment = locator.locations?.fragments?.first {
                        let success = await SMILPlayerActor.shared.seekToFragment(
                            sectionIndex: sectionIndex,
                            textId: fragment
                        )
                        if success {
                            debugLog("[CarPlayCoordinator] Restored position to section \(sectionIndex), fragment: \(fragment)")
                        }
                    } else if let totalProg = locator.locations?.totalProgression, totalProg > 0 {
                        debugLog("[CarPlayCoordinator] No fragment, using totalProgression \(totalProg) - starting from beginning")
                    }
                }

                debugLog("[CarPlayCoordinator] Book loaded, ready for playback")
            } catch {
                debugLog("[CarPlayCoordinator] Failed to load/play book: \(error)")
            }
        }
    }

    public var isPlaying: Bool {
        currentPlaybackState?.isPlaying ?? false
    }

    public var currentBookId: String? {
        currentPlaybackState?.bookId
    }

    // MARK: - Progress Sync

    private func startPeriodicSync() async {
        stopPeriodicSync()

        let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
        debugLog("[CarPlayCoordinator] Starting periodic sync with interval \(syncInterval)s")

        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
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
        guard let state = currentPlaybackState,
              let bookId = state.bookId else {
            debugLog("[CarPlayCoordinator] Cannot sync: no playback state or bookId")
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

        let locator = BookLocator(
            href: href,
            type: "application/xhtml+xml",
            title: state.chapterLabel,
            locations: locations,
            text: nil
        )

        let timestampMs = Date().timeIntervalSince1970 * 1000

        debugLog("[CarPlayCoordinator] Syncing progress: book=\(bookId), href=\(href), fragment=\(fragment ?? "none"), reason=\(reason)")

        let result = await ProgressSyncActor.shared.syncProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestampMs,
            reason: reason
        )

        debugLog("[CarPlayCoordinator] Sync result: \(result)")
    }
}
#endif
