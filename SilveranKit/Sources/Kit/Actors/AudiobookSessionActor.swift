import Foundation

public struct AudiobookSessionChapter: Sendable, Codable, Hashable {
    public let id: String
    public let title: String
    public let duration: TimeInterval

    public init(id: String, title: String, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.duration = duration
    }
}

public struct AudiobookSessionServerPosition: Sendable, Codable, Hashable {
    public let title: String?
    public let totalProgression: Double?

    public init(title: String?, totalProgression: Double?) {
        self.title = title
        self.totalProgression = totalProgression
    }
}

public enum AudiobookSessionSleepTimerMode: String, Sendable, Codable {
    case duration
    case endOfChapter
}

public struct AudiobookSessionState: Sendable, Codable, Hashable {
    public let bookID: String
    public let sourceID: String
    public let title: String
    public let author: String
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let bookProgress: Double
    public let currentChapterID: String?
    public let currentChapterIndex: Int?
    public let chapterElapsed: TimeInterval
    public let chapterDuration: TimeInterval
    public let chapterProgress: Double
    public let playbackRate: Double
    public let volume: Double
    public let chapters: [AudiobookSessionChapter]
    public let sleepTimerMode: AudiobookSessionSleepTimerMode?
    public let sleepTimerRemaining: TimeInterval?
    public let pendingServerPosition: AudiobookSessionServerPosition?
}

public enum AudiobookSessionCommand: Sendable {
    case togglePlayPause
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter
    case seekChapterFraction(Double)
    case selectChapter(String)
    case setPlaybackRate(Double)
    case setVolume(Double)
    case startSleepTimer(TimeInterval)
    case startEndOfChapterSleepTimer
    case cancelSleepTimer
    case acceptServerPosition
    case declineServerPosition
}

public enum AudiobookSessionError: Error, LocalizedError, Sendable {
    case bookNotFound(String)
    case localMediaUnavailable(String)
    case audiobookNotOpen

    public var errorDescription: String? {
        switch self {
            case .bookNotFound(let id):
                return "Book not found: \(id)"
            case .localMediaUnavailable(let id):
                return "No downloaded audiobook is available for \(id)."
            case .audiobookNotOpen:
                return "No audiobook is open."
        }
    }
}

/// Platform-neutral audiobook session policy.
///
/// `AudiobookActor` remains the low-level decoder/player. This actor owns the
/// user-visible session lifecycle, progress restoration and synchronization,
/// semantic controls, sleep timers, and the state rendered by platform UIs.
@globalActor
public actor AudiobookSessionActor {
    public static let shared = AudiobookSessionActor()

    private var book: BookMetadata?
    private var mediaURL: URL?
    private var metadata: AudiobookMetadata?
    private var activeSessionID: UUID?
    private var playbackObserverID: UUID?
    private var playbackEventContinuation: AsyncStream<AudiobookPlaybackState>.Continuation?
    private var playbackEventTask: Task<Void, Never>?
    private var incomingPositionObserverID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    private var observers: [UUID: @Sendable (AudiobookSessionState?) -> Void] = [:]

    private var lastObservedIsPlaying = false
    private var lastSyncedLocator: BookLocator?
    private var nextPeriodicSync = Date.distantFuture
    private var syncInterval: TimeInterval = 60
    private var pendingServerPosition: IncomingServerPosition?
    private var lastRestartTime: Date?

    private var sleepTimerMode: AudiobookSessionSleepTimerMode?
    private var sleepTimerRemaining: TimeInterval?
    private var sleepTimerChapterID: String?
    private var lastSleepTimerUpdate = Date()

    private init() {}

    public func open(bookID: BookID) async throws {
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
        guard let book = snapshot.books.first(where: { $0.id == bookID }) else {
            throw AudiobookSessionError.bookNotFound(bookID.uuid)
        }
        guard
            let media = await BookServiceActor.shared.resolveLocalMedia(
                for: bookID,
                category: .audio,
            )
        else {
            throw AudiobookSessionError.localMediaUnavailable(bookID.uuid)
        }

        try await open(book: book, mediaURL: media.url)
    }

    public func open(book: BookMetadata, mediaURL: URL) async throws {
        if self.book?.id == book.id,
            self.mediaURL?.standardizedFileURL == mediaURL.standardizedFileURL,
            metadata != nil
        {
            await publishState()
            return
        }

        await teardown(syncReason: self.book == nil ? nil : .userClosedBook)

        let sessionID = UUID()
        activeSessionID = sessionID
        self.book = book
        self.mediaURL = mediaURL

        do {
            if await SMILPlayerActor.shared.activeAudioPlayer == .smil {
                await SMILPlayerActor.shared.cleanup()
            }
            await AudiobookActor.shared.cleanup()

            let loadedMetadata = try await AudiobookActor.shared.validateAndLoadAudiobook(
                url: mediaURL
            )
            metadata = loadedMetadata

            let config = await SettingsActor.shared.config
            syncInterval = config.sync.progressSyncIntervalSeconds
            await AudiobookActor.shared.setPlaybackRate(config.playback.defaultPlaybackSpeed)
            await AudiobookActor.shared.setVolume(config.playback.defaultVolume)

            let progression = min(max(await initialProgression(for: book) ?? 0, 0), 1)
            if progression > 0 {
                try await AudiobookActor.shared.preparePlayer(
                    at: loadedMetadata.totalDuration * progression
                )
            } else {
                try await AudiobookActor.shared.preparePlayer()
            }
            if let state = await AudiobookActor.shared.getCurrentState() {
                lastObservedIsPlaying = state.isPlaying
                lastSyncedLocator = makeLocator(state: state, metadata: loadedMetadata)
            }

            await installPlaybackObserver(for: sessionID)
            incomingPositionObserverID = await ProgressSyncActor.shared
                .addIncomingPositionObserver(for: book.id) { position in
                    Task {
                        await AudiobookSessionActor.shared.handleIncomingPosition(
                            position,
                            sessionID: sessionID,
                        )
                    }
                }

            nextPeriodicSync =
                syncInterval > 0 ? Date().addingTimeInterval(syncInterval) : .distantFuture
            startRefreshTask()
            await publishState()
            startCoverTask(for: book, sessionID: sessionID)
        } catch {
            await teardown(syncReason: nil)
            notifyObservers(nil)
            throw error
        }
    }

    public func close() async {
        await teardown(syncReason: .userClosedBook)
        notifyObservers(nil)
    }

    public func control(_ command: AudiobookSessionCommand) async throws {
        guard metadata != nil else { throw AudiobookSessionError.audiobookNotOpen }

        switch command {
            case .togglePlayPause:
                try await AudiobookActor.shared.togglePlayPause()
            case .skipBackward:
                await AudiobookActor.shared.skipBackward()
            case .skipForward:
                await AudiobookActor.shared.skipForward()
            case .previousChapter:
                await previousChapter()
            case .nextChapter:
                await AudiobookActor.shared.skipToNextChapter()
            case .seekChapterFraction(let fraction):
                await seekWithinCurrentChapter(fraction: fraction)
            case .selectChapter(let chapterID):
                await AudiobookActor.shared.seekToChapter(href: chapterID)
            case .setPlaybackRate(let value):
                let rate = min(max(value, 0.5), 10)
                await AudiobookActor.shared.setPlaybackRate(rate)
                try await SettingsActor.shared.updateConfig(defaultPlaybackSpeed: rate)
            case .setVolume(let value):
                let volume = min(max(value, 0), 1)
                await AudiobookActor.shared.setVolume(volume)
                try await SettingsActor.shared.updateConfig(defaultVolume: volume)
            case .startSleepTimer(let seconds):
                startSleepTimer(seconds: seconds)
            case .startEndOfChapterSleepTimer:
                await startEndOfChapterSleepTimer()
            case .cancelSleepTimer:
                cancelSleepTimer()
            case .acceptServerPosition:
                await acceptServerPosition()
            case .declineServerPosition:
                pendingServerPosition = nil
        }

        await publishState()
    }

    @discardableResult
    public func addStateObserver(
        id: UUID = UUID(),
        _ observer: @escaping @Sendable (AudiobookSessionState?) -> Void,
    ) async -> UUID {
        observers[id] = observer
        observer(await makeState())
        return id
    }

    public func removeStateObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func currentState() async -> AudiobookSessionState? {
        await makeState()
    }

    private func installPlaybackObserver(for sessionID: UUID) async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudiobookPlaybackState.self
        )
        playbackEventContinuation = continuation
        playbackEventTask = Task { [weak self] in
            for await state in stream {
                guard !Task.isCancelled, let self else { return }
                await self.handlePlaybackStateChange(state, sessionID: sessionID)
            }
        }
        playbackObserverID = await AudiobookActor.shared.addStateObserver { state in
            continuation.yield(state)
        }
    }

    private func handlePlaybackStateChange(
        _ state: AudiobookPlaybackState,
        sessionID: UUID,
    ) async {
        guard activeSessionID == sessionID else { return }
        let shouldSyncPause = lastObservedIsPlaying && !state.isPlaying
        lastObservedIsPlaying = state.isPlaying

        if shouldSyncPause {
            await syncProgress(reason: .userPausedPlayback)
        }
        await publishState(using: state)
    }

    private func handleIncomingPosition(
        _ position: IncomingServerPosition,
        sessionID: UUID,
    ) async {
        guard activeSessionID == sessionID, book != nil else { return }
        let config = await SettingsActor.shared.config
        if config.sync.autoSyncToNewerServerPosition {
            await navigate(to: position)
        } else {
            pendingServerPosition = position
            await publishState()
        }
    }

    private func acceptServerPosition() async {
        guard let position = pendingServerPosition else { return }
        pendingServerPosition = nil
        await navigate(to: position)
    }

    private func navigate(to position: IncomingServerPosition) async {
        guard let progression = position.locator.locations?.totalProgression else { return }
        let clampedProgression = min(max(progression, 0), 1)
        await AudiobookActor.shared.seekToTotalProgressFraction(clampedProgression)
        if let metadata, let state = await AudiobookActor.shared.getCurrentState() {
            lastSyncedLocator = makeLocator(state: state, metadata: metadata)
        }
        pendingServerPosition = nil
    }

    private func previousChapter() async {
        guard let metadata,
            let index = await AudiobookActor.shared.getCurrentChapterIndex(),
            metadata.chapters.indices.contains(index),
            let state = await AudiobookActor.shared.getCurrentState()
        else { return }

        let chapter = metadata.chapters[index]
        let progress =
            chapter.duration > 0
            ? max(0, state.currentTime - chapter.startTime) / chapter.duration
            : 0
        let now = Date()
        let justRestarted = lastRestartTime.map { now.timeIntervalSince($0) < 2 } ?? false

        if progress > 0.01 && !justRestarted {
            await AudiobookActor.shared.seekToChapter(href: chapter.id)
            lastRestartTime = now
        } else if index > 0 {
            await AudiobookActor.shared.seekToChapter(href: metadata.chapters[index - 1].id)
            lastRestartTime = nil
        } else {
            await AudiobookActor.shared.seekToChapter(href: chapter.id)
            lastRestartTime = now
        }
    }

    private func seekWithinCurrentChapter(fraction: Double) async {
        guard let metadata,
            let index = await AudiobookActor.shared.getCurrentChapterIndex(),
            metadata.chapters.indices.contains(index)
        else { return }

        let chapter = metadata.chapters[index]
        let clampedFraction = min(max(fraction, 0), 1)
        await AudiobookActor.shared.seek(
            to: chapter.startTime + chapter.duration * clampedFraction
        )
    }

    private func startSleepTimer(seconds: TimeInterval) {
        guard seconds > 0 else {
            cancelSleepTimer()
            return
        }
        sleepTimerMode = .duration
        sleepTimerRemaining = seconds
        sleepTimerChapterID = nil
        lastSleepTimerUpdate = Date()
    }

    private func startEndOfChapterSleepTimer() async {
        let index = await AudiobookActor.shared.getCurrentChapterIndex()
        sleepTimerMode = .endOfChapter
        sleepTimerRemaining = nil
        sleepTimerChapterID = index.flatMap { metadata?.chapters[safe: $0]?.id }
        lastSleepTimerUpdate = Date()
    }

    private func cancelSleepTimer() {
        sleepTimerMode = nil
        sleepTimerRemaining = nil
        sleepTimerChapterID = nil
    }

    private func startRefreshTask() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func refresh() async {
        guard let state = await AudiobookActor.shared.getCurrentState() else { return }
        await updateSleepTimer(using: state)

        if state.isPlaying, syncInterval > 0, Date() >= nextPeriodicSync {
            await syncProgress(reason: .periodicDuringActivePlayback)
            nextPeriodicSync = Date().addingTimeInterval(syncInterval)
        }
        await publishState(using: state)
    }

    private func updateSleepTimer(using state: AudiobookPlaybackState) async {
        let now = Date()
        defer { lastSleepTimerUpdate = now }
        guard state.isPlaying, let sleepTimerMode else { return }

        switch sleepTimerMode {
            case .duration:
                let remaining = max(
                    0,
                    (sleepTimerRemaining ?? 0) - now.timeIntervalSince(lastSleepTimerUpdate),
                )
                sleepTimerRemaining = remaining
                if remaining <= 0 {
                    cancelSleepTimer()
                    await AudiobookActor.shared.pause()
                }
            case .endOfChapter:
                guard let metadata,
                    let index = state.currentChapterIndex,
                    metadata.chapters.indices.contains(index)
                else { return }
                let chapter = metadata.chapters[index]
                let elapsed = max(0, state.currentTime - chapter.startTime)
                if chapter.id != sleepTimerChapterID || elapsed >= chapter.duration - 0.5 {
                    cancelSleepTimer()
                    await AudiobookActor.shared.pause()
                }
        }
    }

    private func publishState(using suppliedState: AudiobookPlaybackState? = nil) async {
        notifyObservers(await makeState(using: suppliedState))
    }

    private func makeState(
        using suppliedState: AudiobookPlaybackState? = nil
    ) async -> AudiobookSessionState? {
        guard let book, let metadata else { return nil }

        let state: AudiobookPlaybackState
        if let suppliedState {
            state = suppliedState
        } else if let currentState = await AudiobookActor.shared.getCurrentState() {
            state = currentState
        } else {
            return nil
        }

        let chapter = state.currentChapterIndex.flatMap { metadata.chapters[safe: $0] }
        let rawChapterElapsed = chapter.map { state.currentTime - $0.startTime } ?? 0
        let chapterDuration = chapter?.duration ?? 0
        let chapterElapsed = min(max(rawChapterElapsed, 0), max(chapterDuration, 0))
        let chapterProgress =
            chapterDuration > 0 ? min(max(chapterElapsed / chapterDuration, 0), 1) : 0
        let bookProgress =
            state.duration > 0 ? min(max(state.currentTime / state.duration, 0), 1) : 0

        return AudiobookSessionState(
            bookID: book.uuid,
            sourceID: book.sourceID,
            title: book.title,
            author: book.authors?.first?.name ?? metadata.author ?? "",
            isPlaying: state.isPlaying,
            currentTime: state.currentTime,
            duration: state.duration,
            bookProgress: bookProgress,
            currentChapterID: chapter?.id,
            currentChapterIndex: state.currentChapterIndex,
            chapterElapsed: chapterElapsed,
            chapterDuration: chapterDuration,
            chapterProgress: chapterProgress,
            playbackRate: Double(state.playbackRate),
            volume: Double(state.volume),
            chapters: metadata.chapters.map {
                AudiobookSessionChapter(id: $0.id, title: $0.title, duration: $0.duration)
            },
            sleepTimerMode: sleepTimerMode,
            sleepTimerRemaining: sleepTimerRemaining,
            pendingServerPosition: pendingServerPosition.map {
                AudiobookSessionServerPosition(
                    title: $0.locator.title,
                    totalProgression: $0.locator.locations?.totalProgression,
                )
            },
        )
    }

    private func notifyObservers(_ state: AudiobookSessionState?) {
        for observer in observers.values {
            observer(state)
        }
    }

    private func syncProgress(reason: SyncReason) async {
        guard let book, let metadata,
            let state = await AudiobookActor.shared.getCurrentState()
        else { return }

        let chapter = state.currentChapterIndex.flatMap { metadata.chapters[safe: $0] }
        let chapterProgress =
            chapter.map {
                $0.duration > 0
                    ? min(max((state.currentTime - $0.startTime) / $0.duration, 0), 1)
                    : 0
            } ?? 0
        let locator = makeLocator(state: state, metadata: metadata)
        guard locator != lastSyncedLocator else { return }
        let result = await ProgressSyncActor.shared.syncProgress(
            bookID: book.id,
            locator: locator,
            timestamp: floor(Date().timeIntervalSince1970 * 1_000),
            reason: reason,
            sourceIdentifier: "Audiobook Player",
            locationDescription: "\(chapter?.title ?? "Audiobook"), \(Int(chapterProgress * 100))%",
        )
        switch result {
            case .success, .queued:
                lastSyncedLocator = locator
            case .failed:
                break
        }
    }

    private func makeLocator(
        state: AudiobookPlaybackState,
        metadata: AudiobookMetadata,
    ) -> BookLocator {
        let progress = state.duration > 0 ? state.currentTime / state.duration : 0
        let chapter = state.currentChapterIndex.flatMap { metadata.chapters[safe: $0] }
        let chapterProgress =
            chapter.map {
                $0.duration > 0
                    ? min(max((state.currentTime - $0.startTime) / $0.duration, 0), 1)
                    : 0
            } ?? 0
        return BookLocator(
            href: state.currentTrackHref ?? "audiobook",
            type: state.currentTrackType ?? "audio/mp4",
            title: chapter?.title,
            locations: BookLocator.Locations(
                fragments: ["t=\(state.currentTrackTime)"],
                progression: chapterProgress,
                position: nil,
                totalProgression: progress,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
    }

    private func initialProgression(for book: BookMetadata) async -> Double? {
        if let progress = await ProgressSyncActor.shared.getBookProgress(for: book.id),
            let progression = progress.locator?.locations?.totalProgression
        {
            return progression
        }
        return book.position?.locator?.locations?.totalProgression
    }

    private func coverData(for book: BookMetadata) async -> Data? {
        if let data = await BookServiceActor.shared.cachedCoverData(for: book.id, audio: true) {
            return data
        }
        if let data = await BookServiceActor.shared.cachedCoverData(for: book.id, audio: false) {
            return data
        }

        for audio in [true, false] {
            let response = await BookServiceActor.shared.loadCover(
                for: book.id,
                audio: audio,
                width: 1_024,
                height: 1_024,
                version: book.updatedAt,
                allowNetwork: true,
                policy: .cachedThenFetch,
            )
            switch response {
                case .cached(let data): return data
                case .fetched(let cover): return cover.data
                case .missing, .skippedOffline: continue
            }
        }
        return nil
    }

    private func startCoverTask(for book: BookMetadata, sessionID: UUID) {
        coverTask?.cancel()
        coverTask = Task { [weak self] in
            guard let self, let cover = await self.coverData(for: book), !Task.isCancelled else {
                return
            }
            await self.applyCover(cover, sessionID: sessionID)
        }
    }

    private func applyCover(_ cover: Data, sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        await AudiobookActor.shared.setCoverImage(cover)
    }

    private func teardown(syncReason: SyncReason?) async {
        activeSessionID = nil
        refreshTask?.cancel()
        refreshTask = nil
        coverTask?.cancel()
        coverTask = nil

        if let playbackObserverID {
            await AudiobookActor.shared.removeStateObserver(id: playbackObserverID)
        }
        playbackEventContinuation?.finish()
        playbackEventContinuation = nil
        playbackEventTask?.cancel()
        playbackEventTask = nil
        if let incomingPositionObserverID {
            await ProgressSyncActor.shared.removeIncomingPositionObserver(
                id: incomingPositionObserverID
            )
        }
        if let syncReason {
            await syncProgress(reason: syncReason)
        }
        await AudiobookActor.shared.cleanup()

        book = nil
        mediaURL = nil
        metadata = nil
        playbackObserverID = nil
        incomingPositionObserverID = nil
        lastObservedIsPlaying = false
        lastSyncedLocator = nil
        nextPeriodicSync = .distantFuture
        syncInterval = 60
        pendingServerPosition = nil
        lastRestartTime = nil
        cancelSleepTimer()
    }
}
