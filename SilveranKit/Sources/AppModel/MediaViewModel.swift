import Foundation
import Observation
import SilveranKitCommon
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class MediaViewModel {
    public var library: BookLibrary
    public var libraryVersion: Int = 0
    public var isReady: Bool = false
    public var connectionStatus: ConnectionStatus = .disconnected
    public var availableStatuses: [BookStatus] = []
    public var lastNetworkOpSucceeded: Bool? = nil
    public var cachedConfig: SilveranGlobalConfig = SilveranGlobalConfig()
    public var pendingSyncsByBook: [String: PendingProgressSync] = [:]
    public var syncNotification: SyncNotification?
    var bookProgressCache: [String: BookProgress] = [:]

    private let lma: LocalMediaActor = LocalMediaActor.shared
    private let sta: StorytellerActor = StorytellerActor.shared

    private struct DownloadKey: Hashable {
        let bookID: String
        let category: LocalMediaCategory
    }

    @ObservationIgnored private var downloadTasks: [DownloadKey: Task<Void, Never>] = [:]
    var downloadStatuses: [String: DownloadProgressState] = [:]
    private var cachedBookPaths: [String: MediaPaths] = [:]
    private var localStandaloneBookIds: Set<String> = []
    @ObservationIgnored private var metadataRefreshTask: Task<Void, Never>?

    public struct DownloadProgressState: Equatable {
        public struct CategoryState: Equatable {
            public var expected: Int64?
            public var latestReceived: Int64 = 0
            public var isFinished: Bool = false
            public var wasSkipped: Bool = false

            public var progressFraction: Double? {
                guard let expected, expected > 0 else { return nil }
                return min(max(Double(latestReceived) / Double(expected), 0), 1)
            }

            public var isActive: Bool {
                !isFinished && !wasSkipped
            }
        }

        public var categories: [LocalMediaCategory: CategoryState] = [:]
        public var errorDescription: String?

        public var totalReceived: Int64 {
            categories.values.reduce(0) { $0 + $1.latestReceived }
        }

        public var totalExpected: Int64? {
            guard !categories.isEmpty else { return nil }
            var sum: Int64 = 0
            for state in categories.values {
                guard let expected = state.expected else { return nil }
                sum += expected
            }
            return sum
        }

        public var progressFraction: Double? {
            guard let totalExpected = totalExpected, totalExpected > 0 else { return nil }
            return min(max(Double(totalReceived) / Double(totalExpected), 0), 1)
        }

        public var isActive: Bool {
            categories.values.contains { $0.isActive }
        }

        public var isCompleted: Bool {
            !categories.isEmpty && categories.values.allSatisfy { $0.isFinished || $0.wasSkipped }
        }

        public var hasError: Bool { errorDescription != nil }
    }

    public enum CoverVariant: Hashable {
        case standard
        case audioSquare

        public var requestParameters: (audio: Bool, width: Int, height: Int) {
            switch self {
                case .standard:
                    return (audio: false, width: 209, height: 320)
                case .audioSquare:
                    return (audio: true, width: 209, height: 209)
            }
        }

        public var preferredAspectRatio: CGFloat {
            switch self {
                case .standard:
                    return 2.0 / 3.0
                case .audioSquare:
                    return 1.0
            }
        }
    }

    private struct CoverKey: Hashable {
        let id: String
        let variant: CoverVariant
    }

    @MainActor
    @Observable
    public final class CoverImageState {
        public var image: Image?
        public init(image: Image? = nil) { self.image = image }
    }

    @ObservationIgnored private var coverStates: [CoverKey: CoverImageState] = [:]
    private var missingCoverKeys: Set<CoverKey> = []
    @ObservationIgnored private var coverTasks: [CoverKey: Task<Void, Never>] = [:]

    public init(
        injectLibrary: BookLibrary? = nil,
    ) {
        if let injectLibrary = injectLibrary {
            self.library = injectLibrary
        } else {
            self.library = BookLibrary(
                bookMetaData: [],
                ebookCoverCache: [:],
                audiobookCoverCache: [:]
            )
            Task { [weak self] in
                await ProgressSyncActor.shared.registerSyncNotificationCallback {
                    @MainActor [weak self] synced, failed in
                    guard let self else { return }
                    if synced > 0 {
                        let message =
                            synced == 1
                            ? "Synced reading progress for 1 book"
                            : "Synced reading progress for \(synced) books"
                        self.showSyncNotification(
                            SyncNotification(message: message, type: .success)
                        )
                    } else if failed > 0 {
                        self.showSyncNotification(
                            SyncNotification(
                                message: "Failed to sync \(failed) book(s)",
                                type: .error
                            )
                        )
                    }
                }

                await ProgressSyncActor.shared.startPolling()

                let initialStatus = await StorytellerActor.shared.connectionStatus
                debugLog(
                    "[MediaViewModel] init: Setting initial connectionStatus to \(initialStatus)"
                )
                await MainActor.run { [weak self] in
                    self?.connectionStatus = initialStatus
                    debugLog(
                        "[MediaViewModel] init: connectionStatus is now \(self?.connectionStatus ?? .disconnected)"
                    )
                }

                await StorytellerActor.shared.request_notify { @MainActor [weak self] in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let status = await StorytellerActor.shared.connectionStatus
                        let networkOp = await StorytellerActor.shared.lastNetworkOpSucceeded
                        let wasConnected = self.connectionStatus == .connected
                        self.connectionStatus = status
                        self.lastNetworkOpSucceeded = networkOp
                        debugLog(
                            "[MediaViewModel] StorytellerActor notify: connectionStatus=\(status), lastNetworkOpSucceeded=\(String(describing: networkOp))"
                        )
                        if !wasConnected && status == .connected && self.availableStatuses.isEmpty {
                            let statuses = await StorytellerActor.shared.getAvailableStatuses()
                            self.availableStatuses = statuses
                        }
                    }
                }
            }
            setupPathCacheSync()
            setupSettingsSync()
            startMetadataRefreshTask()
        }
    }

    public func refreshMetadata(source: String = "unknown") async {
        let status = await StorytellerActor.shared.connectionStatus
        let storytellerPaths = await LocalMediaActor.shared.localStorytellerBookPaths
        let standalonePaths = await LocalMediaActor.shared.localStandaloneBookPaths
        let paths = storytellerPaths.merging(standalonePaths) { _, new in new }
        let pendingSyncs = await ProgressSyncActor.shared.getPendingProgressSyncs()

        debugLog(
            "[MediaViewModel] refreshMetadata: Status: \(status), pendingSyncs count: \(pendingSyncs.count)"
        )
        if !pendingSyncs.isEmpty {
            let bookIds = pendingSyncs.map { $0.bookId }.joined(separator: ", ")
            debugLog("[MediaViewModel] refreshMetadata: Pending bookIds: [\(bookIds)]")
        }

        let storytellerMetadata = await LocalMediaActor.shared.localStorytellerMetadata
        let standaloneMetadata = await LocalMediaActor.shared.localStandaloneMetadata
        let metadata = storytellerMetadata + standaloneMetadata
        debugLog(
            "[MediaViewModel] refreshMetadata: Using LMA metadata (\(storytellerMetadata.count) storyteller + \(standaloneMetadata.count) standalone = \(metadata.count) books)"
        )

        pendingSyncsByBook = Dictionary(uniqueKeysWithValues: pendingSyncs.map { ($0.bookId, $0) })
        debugLog(
            "[MediaViewModel] refreshMetadata: Set pendingSyncsByBook to \(pendingSyncsByBook.count) books"
        )

        bookProgressCache = await ProgressSyncActor.shared.getAllBookProgress()
        debugLog(
            "[MediaViewModel] refreshMetadata: Loaded \(bookProgressCache.count) progress entries from PSA"
        )

        applyLibraryMetadata(metadata)
        cachedBookPaths = paths
        localStandaloneBookIds = Set(standaloneMetadata.map { $0.uuid })
        connectionStatus = status
        lastNetworkOpSucceeded = await StorytellerActor.shared.lastNetworkOpSucceeded
        isReady = true
        debugLog(
            "[MediaViewModel] refreshMetadata: connectionStatus=\(status), lastNetworkOpSucceeded=\(String(describing: lastNetworkOpSucceeded))"
        )
        debugLog(
            "[MediaViewModel] refreshMetadata: Complete - library has \(library.bookMetaData.count) books"
        )

        await loadCachedCoversFromDisk()
    }

    private func startMetadataRefreshTask() {
        restartMetadataRefreshTask()
    }

    private func restartMetadataRefreshTask() {
        metadataRefreshTask?.cancel()

        metadataRefreshTask = Task { [weak self] in
            while true {
                guard self != nil else { return }

                let config = await SettingsActor.shared.config
                // Use minimum of metadata and progress sync intervals, since incoming
                // progress sync data comes from metadata fetches
                let refreshInterval = min(
                    config.sync.metadataRefreshIntervalSeconds,
                    config.sync.progressSyncIntervalSeconds
                )

                if config.sync.isMetadataRefreshDisabled {
                    debugLog("[MediaViewModel] Metadata auto-refresh is disabled")
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { return }
                    continue
                }

                debugLog("[MediaViewModel] Next metadata refresh in \(Int(refreshInterval))s")
                try? await Task.sleep(for: .seconds(refreshInterval))

                guard !Task.isCancelled else {
                    return
                }

                debugLog(
                    "[MediaViewModel] Periodic metadata refresh (interval: \(Int(refreshInterval))s, min of metadata/progress sync)"
                )

                let status = await StorytellerActor.shared.connectionStatus
                if status == .connected {
                    let _ = await StorytellerActor.shared.fetchLibraryInformation()
                } else {
                    debugLog(
                        "[MediaViewModel] Skipping Storyteller refresh - not connected to server"
                    )
                }
            }
        }
    }

    private func setupSettingsSync() {
        Task {
            await SettingsActor.shared.request_notify { @MainActor [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let config = await SettingsActor.shared.config
                    self.cachedConfig = config
                    self.restartMetadataRefreshTask()
                }
            }

            let initialConfig = await SettingsActor.shared.config
            await MainActor.run { [weak self] in
                self?.cachedConfig = initialConfig
            }
        }
    }

    private func setupPathCacheSync() {
        Task {
            await LocalMediaActor.shared.addObserver { @MainActor [weak self] in
                Task { @MainActor in
                    await self?.syncPathCache()
                    await self?.refreshMetadata(source: "LocalMediaActor.observer")
                }
            }

            await ProgressSyncActor.shared.addObserver { [weak self] in
                Task { @MainActor in
                    await self?.refreshMetadata(source: "ProgressSyncActor.observer")
                }
            }

            await self.refreshMetadata(source: "init")
        }
    }

    private func syncPathCache() async {
        let storytellerPaths = await LocalMediaActor.shared.localStorytellerBookPaths
        let standalonePaths = await LocalMediaActor.shared.localStandaloneBookPaths
        cachedBookPaths = storytellerPaths.merging(standalonePaths) { _, new in new }
    }

    private func applyLibraryMetadata(_ metadata: [BookMetadata]) {
        let validIDs = Set(metadata.map(\.id))
        library = BookLibrary(
            bookMetaData: metadata,
            ebookCoverCache: [:],
            audiobookCoverCache: [:]
        )
        libraryVersion += 1
        debugLog("[MediaViewModel] Updated library (version \(libraryVersion))")

        let invalidKeys = coverStates.keys.filter { !validIDs.contains($0.id) }
        for key in invalidKeys {
            coverStates.removeValue(forKey: key)
        }
        missingCoverKeys = Set(missingCoverKeys.filter { validIDs.contains($0.id) })
        pruneCoverTasks(keeping: validIDs)
    }

    private func pruneCoverTasks(keeping validIDs: Set<String>) {
        let invalidKeys = coverTasks.keys.filter { !validIDs.contains($0.id) }
        for key in invalidKeys {
            coverTasks[key]?.cancel()
            coverTasks.removeValue(forKey: key)
        }
    }

    private func metadataMatchesKind(_ metadata: BookMetadata, kind: MediaKind) -> Bool {
        switch kind {
            case .ebook:
                return metadata.hasAvailableEbook || metadata.hasAvailableReadaloud
            case .audiobook:
                return !metadata.hasAvailableEbook && !metadata.hasAvailableReadaloud
                    && metadata.hasAvailableAudiobook
        }
    }
    public func items(for kind: MediaKind, narrationFilter: NarrationFilter, tagFilter: String?)
        -> [BookMetadata]
    {
        var base = library.bookMetaData.filter { metadataMatchesKind($0, kind: kind) }
        switch narrationFilter {
            case .both:
                break
            case .withAudio:
                base = base.filter(\.hasAnyAudiobookAsset)
            case .withoutAudio:
                base = base.filter { !$0.hasAnyAudiobookAsset }
        }
        if let tagFilter, !tagFilter.isEmpty {
            let target = tagFilter.lowercased()
            base = base.filter { item in
                item.tagNames.contains(where: { $0.lowercased() == target })
            }
        }
        return base
    }

    public func itemsByStatus(_ statusName: String, sortBy: StatusSortOrder, limit: Int)
        -> [BookMetadata]
    {
        let filtered = library.bookMetaData.filter { metadata in
            metadata.status?.name == statusName
        }

        let sorted: [BookMetadata]
        switch sortBy {
            case .recentPositionUpdate:
                sorted = filtered.sorted { a, b in
                    let tsA = bookProgressCache[a.id]?.timestamp ?? 0
                    let tsB = bookProgressCache[b.id]?.timestamp ?? 0
                    return tsA > tsB
                }
            case .recentlyAdded:
                sorted = filtered.sorted { a, b in
                    (a.createdAt ?? "") > (b.createdAt ?? "")
                }
        }

        return Array(sorted.prefix(limit))
    }

    public func recentlyAddedItems(limit: Int) -> [BookMetadata] {
        let sorted = library.bookMetaData.sorted { a, b in
            (a.createdAt ?? "") > (b.createdAt ?? "")
        }
        return Array(sorted.prefix(limit))
    }

    public func booksBySeries(for kind: MediaKind)
        -> [(series: BookSeries?, books: [BookMetadata])]
    {
        let allBooks = library.bookMetaData

        var seriesMap: [String: (series: BookSeries?, books: [BookMetadata])] = [:]

        for book in allBooks {
            if let seriesList = book.series, let firstSeries = seriesList.first {
                let key = firstSeries.uuid ?? firstSeries.name
                if var existing = seriesMap[key] {
                    existing.books.append(book)
                    seriesMap[key] = existing
                } else {
                    seriesMap[key] = (series: firstSeries, books: [book])
                }
            } else {
                if var existing = seriesMap["__no_series__"] {
                    existing.books.append(book)
                    seriesMap["__no_series__"] = existing
                } else {
                    seriesMap["__no_series__"] = (series: nil, books: [book])
                }
            }
        }

        for key in seriesMap.keys {
            seriesMap[key]?.books.sort { a, b in
                let posA = a.series?.first?.position ?? Int.max
                let posB = b.series?.first?.position ?? Int.max
                return posA < posB
            }
        }

        var result = Array(seriesMap.values)
        result.sort { a, b in
            guard let seriesA = a.series, let seriesB = b.series else {
                return a.series != nil
            }
            return seriesA.name.localizedCaseInsensitiveCompare(seriesB.name) == .orderedAscending
        }

        return result
    }

    public func booksByAuthor(for kind: MediaKind)
        -> [(author: BookCreator?, books: [BookMetadata])]
    {
        let allBooks = library.bookMetaData

        var authorMap: [String: (author: BookCreator?, books: [BookMetadata])] = [:]

        for book in allBooks {
            if let authorsList = book.authors, let firstAuthor = authorsList.first {
                let key = firstAuthor.uuid ?? firstAuthor.name ?? "__unknown__"
                if var existing = authorMap[key] {
                    existing.books.append(book)
                    authorMap[key] = existing
                } else {
                    authorMap[key] = (author: firstAuthor, books: [book])
                }
            } else {
                if var existing = authorMap["__no_author__"] {
                    existing.books.append(book)
                    authorMap["__no_author__"] = existing
                } else {
                    authorMap["__no_author__"] = (author: nil, books: [book])
                }
            }
        }

        for key in authorMap.keys {
            authorMap[key]?.books.sort { a, b in
                a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        var result = Array(authorMap.values)
        result.sort { a, b in
            guard let authorA = a.author, let authorB = b.author else {
                return a.author != nil
            }
            let nameA = authorA.name ?? ""
            let nameB = authorB.name ?? ""
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }

        return result
    }

    public func booksByCollection(for kind: MediaKind) -> [(
        collection: BookCollectionSummary?, books: [BookMetadata]
    )] {
        let allBooks = library.bookMetaData

        var collectionMap: [String: (collection: BookCollectionSummary?, books: [BookMetadata])] =
            [:]

        for book in allBooks {
            if let collectionsList = book.collections {
                for collection in collectionsList {
                    let key = collection.uuid ?? collection.name
                    if var existing = collectionMap[key] {
                        existing.books.append(book)
                        collectionMap[key] = existing
                    } else {
                        collectionMap[key] = (collection: collection, books: [book])
                    }
                }
            }
        }

        for key in collectionMap.keys {
            collectionMap[key]?.books.sort { a, b in
                a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        var result = Array(collectionMap.values)
        result.sort { a, b in
            guard let collectionA = a.collection, let collectionB = b.collection else {
                return a.collection != nil
            }
            return collectionA.name.localizedCaseInsensitiveCompare(collectionB.name)
                == .orderedAscending
        }

        return result
    }

    public func booksByNarrator(for kind: MediaKind)
        -> [(narrator: BookCreator?, books: [BookMetadata])]
    {
        let allBooks = library.bookMetaData

        var narratorMap: [String: (narrator: BookCreator?, books: [BookMetadata])] = [:]

        for book in allBooks {
            if let narratorsList = book.narrators, let firstNarrator = narratorsList.first {
                let key = firstNarrator.uuid ?? firstNarrator.name ?? "__unknown__"
                if var existing = narratorMap[key] {
                    existing.books.append(book)
                    narratorMap[key] = existing
                } else {
                    narratorMap[key] = (narrator: firstNarrator, books: [book])
                }
            } else {
                if var existing = narratorMap["__no_narrator__"] {
                    existing.books.append(book)
                    narratorMap["__no_narrator__"] = existing
                } else {
                    narratorMap["__no_narrator__"] = (narrator: nil, books: [book])
                }
            }
        }

        for key in narratorMap.keys {
            narratorMap[key]?.books.sort { a, b in
                a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        var result = Array(narratorMap.values)
        result.sort { a, b in
            guard let narratorA = a.narrator, let narratorB = b.narrator else {
                return a.narrator != nil
            }
            let nameA = narratorA.name ?? ""
            let nameB = narratorB.name ?? ""
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }

        return result
    }

    public func booksByTag(for kind: MediaKind) -> [(tag: String, books: [BookMetadata])] {
        let allBooks = library.bookMetaData

        var tagMap: [String: [BookMetadata]] = [:]

        for book in allBooks {
            for tagName in book.tagNames {
                let key = tagName.lowercased()
                if var existing = tagMap[key] {
                    existing.append(book)
                    tagMap[key] = existing
                } else {
                    tagMap[key] = [book]
                }
            }
        }

        for key in tagMap.keys {
            tagMap[key]?.sort { a, b in
                a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        var result: [(tag: String, books: [BookMetadata])] = tagMap.map { (tag: $0.key, books: $0.value) }
        result.sort { a, b in
            a.tag.localizedCaseInsensitiveCompare(b.tag) == .orderedAscending
        }

        return result
    }

    public enum StatusSortOrder {
        case recentPositionUpdate
        case recentlyAdded
    }

    public func badgeCount(for content: SidebarContentKind) -> Int {
        switch content {
            case .home:
                return 0
            case .mediaGrid(let config):
                var base = items(
                    for: config.mediaKind,
                    narrationFilter: .both,
                    tagFilter: config.tagFilter
                )

                if shouldIncludeAudiobookOnlyItems(for: config.narrationFilter) {
                    let audioOnlyItems = items(
                        for: .audiobook,
                        narrationFilter: .both,
                        tagFilter: config.tagFilter
                    )
                    base = mergeItems(base, with: audioOnlyItems)
                }

                base = base.filter { matchesNarrationFilter($0, filter: config.narrationFilter) }

                if let statusFilter = config.statusFilter {
                    base = base.filter { metadata in
                        guard let itemStatus = metadata.status?.name else { return false }
                        return itemStatus.caseInsensitiveCompare(statusFilter) == .orderedSame
                    }
                }

                base = base.filter { matchesLocationFilter($0, filter: config.locationFilter) }

                return base.count
            case .seriesView:
                return library.bookMetaData.filter { book in
                    book.series?.isEmpty == false
                }.count
            case .authorView:
                return library.bookMetaData.filter { book in
                    book.authors?.isEmpty == false
                }.count
            case .narratorView:
                return library.bookMetaData.filter { book in
                    book.narrators?.isEmpty == false
                }.count
            case .tagView:
                return library.bookMetaData.filter { book in
                    book.tags?.isEmpty == false
                }.count
            case .collectionsView:
                return library.bookMetaData.filter { book in
                    book.collections?.isEmpty == false
                }.count
            case .placeholder:
                return 0
            case .importLocalFile:
                return 0
            case .storytellerServer:
                return 0
        }
    }

    private func shouldIncludeAudiobookOnlyItems(for filter: NarrationFilter) -> Bool {
        switch filter {
            case .both, .withAudio:
                return true
            case .withoutAudio:
                return false
        }
    }

    private func matchesNarrationFilter(_ item: BookMetadata, filter: NarrationFilter) -> Bool {
        switch filter {
            case .both:
                return true
            case .withAudio:
                return item.hasAvailableAudiobook || item.hasAvailableReadaloud
            case .withoutAudio:
                return item.isEbookOnly
        }
    }

    private func matchesLocationFilter(_ item: BookMetadata, filter: LocationFilter) -> Bool {
        switch filter {
            case .all:
                return true
            case .downloaded:
                return isCategoryDownloaded(.ebook, for: item)
                    || isCategoryDownloaded(.audio, for: item)
                    || isCategoryDownloaded(.synced, for: item)
            case .serverOnly:
                let hasDownload =
                    isCategoryDownloaded(.ebook, for: item)
                    || isCategoryDownloaded(.audio, for: item)
                    || isCategoryDownloaded(.synced, for: item)
                return !hasDownload && !isLocalStandaloneBook(item.id)
            case .localFiles:
                return isLocalStandaloneBook(item.id)
        }
    }

    private func mergeItems(_ primary: [BookMetadata], with supplemental: [BookMetadata])
        -> [BookMetadata]
    {
        guard !supplemental.isEmpty else { return primary }
        var result = primary
        var seen = Set(result.map(\.id))
        for item in supplemental where !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    public func downloadStatus(for item: BookMetadata) -> DownloadProgressState? {
        downloadStatuses[item.id]
    }

    public func isDownloadInProgress(for item: BookMetadata) -> Bool {
        downloadStatuses[item.id]?.isActive ?? false
            || downloadTasks.keys.contains(where: { $0.bookID == item.id })
    }

    public func startDownload(for item: BookMetadata, category: LocalMediaCategory) {
        let key = DownloadKey(bookID: item.id, category: category)
        guard downloadTasks[key] == nil else { return }

        var status = downloadStatuses[item.id] ?? DownloadProgressState()
        status.categories[category] = DownloadProgressState.CategoryState()
        status.errorDescription = nil
        downloadStatuses[item.id] = status

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(for: item, category: category, key: key)
        }

        downloadTasks[key] = task
    }

    public func cancelDownload(for item: BookMetadata, category: LocalMediaCategory) {
        let key = DownloadKey(bookID: item.id, category: category)
        if let task = downloadTasks[key] {
            task.cancel()
        }
        downloadTasks[key] = nil

        if var state = downloadStatuses[item.id] {
            state.categories.removeValue(forKey: category)
            state.errorDescription = nil
            if state.categories.isEmpty {
                downloadStatuses[item.id] = nil
            } else {
                downloadStatuses[item.id] = state
            }
        }
    }

    public func isCategoryDownloaded(_ category: LocalMediaCategory, for item: BookMetadata) -> Bool
    {
        guard let paths = cachedBookPaths[item.id] else { return false }
        switch category {
            case .ebook:
                return paths.ebookPath != nil
            case .audio:
                return paths.audioPath != nil
            case .synced:
                return paths.syncedPath != nil
        }
    }

    public func localMediaPath(for bookID: String, category: LocalMediaCategory) -> URL? {
        guard let paths = cachedBookPaths[bookID] else { return nil }
        switch category {
            case .ebook:
                return paths.ebookPath
            case .audio:
                return paths.audioPath
            case .synced:
                return paths.syncedPath
        }
    }

    public func isLocalStandaloneBook(_ bookID: String) -> Bool {
        localStandaloneBookIds.contains(bookID)
    }

    public func sourceLabel(for bookID: String) -> String {
        if localStandaloneBookIds.contains(bookID) {
            return "Local File"
        } else {
            return "Storyteller"
        }
    }

    // MARK: - Progress from PSA

    public func progress(for bookId: String) -> Double {
        bookProgressCache[bookId]?.progressFraction ?? 0
    }

    public func position(for bookId: String) -> BookReadingPosition? {
        guard let bp = bookProgressCache[bookId], let locator = bp.locator else { return nil }
        return BookReadingPosition(
            uuid: nil,
            locator: locator,
            timestamp: bp.timestamp,
            createdAt: nil,
            updatedAt: nil
        )
    }

    public func downloadProgressFraction(
        for item: BookMetadata,
        category: LocalMediaCategory
    ) -> Double? {
        downloadStatuses[item.id]?.categories[category]?.progressFraction
    }

    public func isCategoryDownloadInProgress(
        for item: BookMetadata,
        category: LocalMediaCategory
    ) -> Bool {
        downloadStatuses[item.id]?.categories[category]?.isActive ?? false
    }

    public func openMediaFolder(for item: BookMetadata, category: LocalMediaCategory) {
        #if canImport(AppKit)
        Task { [weak self] in
            guard
                let directory = await LocalMediaActor.shared.mediaDirectory(
                    for: item.id,
                    category: category
                )
            else { return }
            await MainActor.run {
                guard self != nil else { return }
                NSWorkspace.shared.activateFileViewerSelecting([directory])
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                    .first?.activate()
            }
        }
        #endif
    }

    public func deleteDownload(for item: BookMetadata, category: LocalMediaCategory) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await LocalMediaActor.shared.deleteMedia(for: item.id, category: category)
                await MainActor.run {
                    if var state = downloadStatuses[item.id] {
                        state.categories[category] = nil
                        downloadStatuses[item.id] = state
                    }
                }
            } catch {
                await MainActor.run {
                    var state = downloadStatuses[item.id] ?? DownloadProgressState()
                    state.errorDescription = error.localizedDescription
                    downloadStatuses[item.id] = state
                }
            }
        }
    }

    private func runDownload(
        for item: BookMetadata,
        category: LocalMediaCategory,
        key: DownloadKey
    ) async {
        defer { downloadTasks[key] = nil }

        let stream = await lma.importMedia(for: item, category: category)
        do {
            for try await event in stream {
                handleDownloadEvent(event)
            }
        } catch is CancellationError {
            if var state = downloadStatuses[item.id] {
                state.categories.removeValue(forKey: category)
                state.errorDescription = nil
                if state.categories.isEmpty {
                    downloadStatuses[item.id] = nil
                } else {
                    downloadStatuses[item.id] = state
                }
            }
        } catch {
            var state = downloadStatuses[item.id] ?? DownloadProgressState()
            var categoryState = state.categories[category] ?? DownloadProgressState.CategoryState()
            categoryState.isFinished = true
            state.categories[category] = categoryState
            state.errorDescription = error.localizedDescription
            downloadStatuses[item.id] = state
        }
    }

    private func handleDownloadEvent(_ event: LocalMediaImportEvent) {
        switch event {
            case .started(let book, let category, let expectedBytes):
                guard
                    var state = downloadStatuses[book.id],
                    var categoryState = state.categories[category]
                else {
                    return
                }
                categoryState.expected = expectedBytes ?? categoryState.expected
                categoryState.latestReceived = 0
                categoryState.isFinished = false
                categoryState.wasSkipped = false
                state.categories[category] = categoryState
                state.errorDescription = nil
                downloadStatuses[book.id] = state

            case .progress(let book, let category, let receivedBytes, let expectedBytes):
                guard
                    var state = downloadStatuses[book.id],
                    var categoryState = state.categories[category]
                else {
                    return
                }
                if let expectedBytes {
                    categoryState.expected = expectedBytes
                }
                categoryState.latestReceived = max(categoryState.latestReceived, receivedBytes)
                state.categories[category] = categoryState
                state.errorDescription = nil
                downloadStatuses[book.id] = state

            case .finished(let book, let category, _):
                guard
                    var state = downloadStatuses[book.id],
                    var categoryState = state.categories[category]
                else {
                    return
                }
                categoryState.isFinished = true
                if let expected = categoryState.expected {
                    categoryState.latestReceived = max(categoryState.latestReceived, expected)
                }
                state.categories[category] = categoryState
                state.errorDescription = nil
                downloadStatuses[book.id] = state

            case .skipped(let book, let category):
                guard
                    var state = downloadStatuses[book.id],
                    var categoryState = state.categories[category]
                else {
                    return
                }
                categoryState.isFinished = true
                categoryState.wasSkipped = true
                state.categories[category] = categoryState
                state.errorDescription = nil
                downloadStatuses[book.id] = state
        }
    }

    public func coverVariant(for item: BookMetadata) -> CoverVariant {
        if item.hasAvailableEbook {
            return .standard
        }
        if item.hasAvailableAudiobook {
            return .audioSquare
        }
        return .standard
    }

    public func coverImage(for item: BookMetadata, variant overrideVariant: CoverVariant? = nil)
        -> Image?
    {
        let variant = overrideVariant ?? coverVariant(for: item)
        let key = CoverKey(id: item.id, variant: variant)
        return coverStates[key]?.image
    }

    public func coverState(for item: BookMetadata, variant overrideVariant: CoverVariant? = nil)
        -> CoverImageState
    {
        let variant = overrideVariant ?? coverVariant(for: item)
        let key = CoverKey(id: item.id, variant: variant)
        if let existing = coverStates[key] { return existing }
        let state = CoverImageState()
        coverStates[key] = state
        return state
    }

    public func ensureCoverLoaded(for item: BookMetadata, variant overrideVariant: CoverVariant? = nil)
    {
        let variant = overrideVariant ?? coverVariant(for: item)
        let key = CoverKey(id: item.id, variant: variant)
        if coverStates[key]?.image != nil || missingCoverKeys.contains(key) {
            return
        }
        if coverTasks[key] != nil {
            return
        }

        if item.hasAvailableAudiobook && variant != .audioSquare {
            ensureCoverLoaded(for: item, variant: .audioSquare)
        }

        coverTasks[key] = Task { [weak self] in
            guard let self else { return }

            let isLocalBook = await LocalMediaActor.shared.isLocalStandaloneBook(item.id)

            if isLocalBook {
                let coverData = await LocalMediaActor.shared.extractLocalCover(for: item.id)
                await MainActor.run {
                    if let data = coverData {
                        let cover = BookCover(
                            data: data,
                            contentType: nil,
                            etag: nil,
                            lastModified: nil,
                            cacheControl: nil,
                            contentDisposition: nil
                        )
                        self.registerCover(cover, for: item, variant: variant)
                    } else {
                        self.missingCoverKeys.insert(key)
                    }
                    self.coverTasks[key] = nil
                }
            } else {
                guard self.connectionStatus == .connected else {
                    await MainActor.run {
                        self.coverTasks[key] = nil
                    }
                    return
                }

                let params = variant.requestParameters
                let cover = await self.sta.fetchCoverImage(
                    for: item.id,
                    audio: params.audio,
                    width: params.width,
                    height: params.height
                )
                await MainActor.run {
                    self.registerCover(cover, for: item, variant: variant)
                    self.coverTasks[key] = nil
                }
            }
        }
    }

    private func registerCover(_ cover: BookCover?, for item: BookMetadata, variant: CoverVariant) {
        let key = CoverKey(id: item.id, variant: variant)
        let state = coverStates[key] ?? CoverImageState()
        coverStates[key] = state

        guard let cover else {
            missingCoverKeys.insert(key)
            state.image = nil
            return
        }

        guard let image = Self.makeImage(from: cover.data) else {
            missingCoverKeys.insert(key)
            state.image = nil
            return
        }

        state.image = image
        missingCoverKeys.remove(key)

        Task {
            let variantString = variant == .standard ? "standard" : "audioSquare"
            try? await FilesystemActor.shared.saveCoverImage(
                uuid: item.id,
                data: cover.data,
                variant: variantString
            )
        }
    }

    private func loadCachedCoversFromDisk() async {
        for book in library.bookMetaData {
            var variantsToLoad: [CoverVariant] = [coverVariant(for: book)]
            if book.hasAvailableAudiobook && !variantsToLoad.contains(.audioSquare) {
                variantsToLoad.append(.audioSquare)
            }

            for variant in variantsToLoad {
                let variantString = variant == .standard ? "standard" : "audioSquare"

                if let data = await FilesystemActor.shared.loadCoverImage(
                    uuid: book.id,
                    variant: variantString
                ) {
                    let key = CoverKey(id: book.id, variant: variant)
                    if let image = Self.makeImage(from: data) {
                        let state = coverStates[key] ?? CoverImageState()
                        coverStates[key] = state
                        state.image = image
                    }
                }
            }
        }
    }

    private static func makeImage(from data: Data) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }

    public func showSyncNotification(_ notification: SyncNotification) {
        syncNotification = notification
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if syncNotification?.id == notification.id {
                syncNotification = nil
            }
        }
    }

    public func dismissSyncNotification() {
        syncNotification = nil
    }
}
