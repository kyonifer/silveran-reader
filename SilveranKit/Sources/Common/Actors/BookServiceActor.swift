import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@globalActor
public actor BookServiceActor {
    public static let shared = BookServiceActor()

    private var sourceRecords: [BookSourceRecord]
    private var sourcesByID: [BookSourceID: any BookSourceActor]
    private var sourceRegistryLoaded = false
    private var lastUpdateErrorsBySourceID: [BookSourceID: String] = [:]
    private var libraryObservers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var localMediaObserverID: UUID?
    private var startupRefreshStarted = false

    public init() {
        self.sourceRecords = []
        self.sourcesByID = [:]
        Task {
            await self.refreshLibraryAfterStartup()
        }
    }

    private func ensureLocalMediaObserver() async {
        guard localMediaObserverID == nil else { return }
        localMediaObserverID = await LocalMediaActor.shared.addObserver {
            Task {
                await BookServiceActor.shared.notifyLibraryObservers()
            }
        }
    }

    private func notifyLibraryObservers() async {
        for (_, callback) in libraryObservers {
            await callback()
        }
    }

    private func refreshLibraryAfterStartup() async {
        guard !startupRefreshStarted else { return }
        startupRefreshStarted = true
        _ = await fetchLibraryInformation()
        await notifyLibraryObservers()
    }

    private func sourceActor(for sourceID: BookSourceID?) -> (any BookSourceActor)? {
        guard let requestedID = sourceID else { return nil }
        if let source = sourcesByID[requestedID] {
            return source
        }
        return nil
    }

    private func closeFolderAccessIfNeeded(sourceID: BookSourceID) async {
        guard let folder = sourcesByID[sourceID] as? FolderSourceActor else { return }
        await folder.closeFolderAccess()
    }

    private func closeAllFolderAccess() async {
        for source in sourcesByID.values {
            guard let folder = source as? FolderSourceActor else { continue }
            await folder.closeFolderAccess()
        }
    }

    private func storytellerActor(for sourceID: BookSourceID?) async -> StorytellerActor? {
        await ensureSourceRegistryLoaded()
        return sourceActor(for: sourceID) as? StorytellerActor
    }

    private func folderSourceActor(for sourceID: BookSourceID?) async -> FolderSourceActor? {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveFolderSourceID(sourceID) else { return nil }
        return sourceActor(for: resolvedSourceID) as? FolderSourceActor
    }

    private func resolveFolderSourceID(_ sourceID: BookSourceID?) -> BookSourceID? {
        if let sourceID,
            sourceRecords.contains(where: { $0.id == sourceID && $0.kind == .localFolder })
        {
            return sourceID
        }
        if sourceID != nil {
            return nil
        }
        return sourceRecords.first(where: { $0.kind == .localFolder })?.id
    }

    private func resolveExplicitSourceID(_ sourceID: BookSourceID?) -> BookSourceID? {
        guard let sourceID else { return nil }

        if sourcesByID[sourceID] != nil {
            return sourceID
        }
        return sourceID
    }

    public var bookSources: [BookSourceRecord] {
        get async {
            await ensureSourceRegistryLoaded()
            return sourceRecords
        }
    }

    public func lastUpdateBookError(sourceID: BookSourceID?) async -> String? {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID) else {
            return "Book metadata is missing source ID."
        }
        if let actorError = await storytellerActor(for: resolvedSourceID)?.lastUpdateBookError {
            return actorError
        }
        return lastUpdateErrorsBySourceID[resolvedSourceID]
    }

    public var connectionStatus: ConnectionStatus {
        get async {
            await ensureSourceRegistryLoaded()
            var sawConnecting = false
            var firstError: String?
            for record in sourceRecords {
                guard let source = sourcesByID[record.id] else { continue }
                switch await source.connectionStatus {
                    case .connected:
                        return .connected
                    case .connecting:
                        sawConnecting = true
                    case .error(let message):
                        firstError = firstError ?? message
                    case .disconnected:
                        break
                }
            }
            if sawConnecting { return .connecting }
            if let firstError { return .error(firstError) }
            return .disconnected
        }
    }

    public func connectionStatus(sourceID: BookSourceID?) async -> ConnectionStatus {
        await ensureSourceRegistryLoaded()
        guard let source = sourceActor(for: sourceID) else { return .disconnected }
        return await source.connectionStatus
    }

    public func hasConnectedSource() async -> Bool {
        await ensureSourceRegistryLoaded()
        for record in sourceRecords {
            guard let source = sourcesByID[record.id] else { continue }
            if await source.connectionStatus == .connected {
                return true
            }
        }
        return false
    }

    public func sourceConnectionInfos() async -> [SourceConnectionInfo] {
        await ensureSourceRegistryLoaded()
        var result: [SourceConnectionInfo] = []
        for record in sourceRecords {
            guard let source = sourcesByID[record.id] else { continue }
            let status = await source.connectionStatus
            var netOpSucceeded: Bool? = nil
            if let storyteller = source as? StorytellerActor {
                netOpSucceeded = await storyteller.lastNetworkOpSucceeded
            }
            result.append(
                SourceConnectionInfo(
                    id: record.id,
                    name: record.name,
                    kind: record.kind,
                    status: status,
                    lastNetworkOpSucceeded: netOpSucceeded,
                )
            )
        }
        return result
    }

    public var isConfigured: Bool {
        get async {
            await ensureSourceRegistryLoaded()
            for actor in storytellerActors() {
                if await actor.isConfigured {
                    return true
                }
            }
            return false
        }
    }

    public var lastNetworkOpSucceeded: Bool? {
        get async {
            await ensureSourceRegistryLoaded()
            var sawValue = false
            for actor in storytellerActors() {
                guard let succeeded = await actor.lastNetworkOpSucceeded else { continue }
                sawValue = true
                if !succeeded {
                    return false
                }
            }
            return sawValue ? true : nil
        }
    }

    public func request_notify(callback: @Sendable @MainActor @escaping () -> Void) async {
        await ensureSourceRegistryLoaded()
        for actor in storytellerActors() {
            await actor.request_notify(callback: callback)
        }
    }

    public func setActive(_ active: Bool, source: ActivitySource) async {
        await ensureSourceRegistryLoaded()
        for actor in storytellerActors() {
            await actor.setActive(active, source: source)
        }
    }

    public func setLogin(
        sourceID: BookSourceID,
        baseURL baseURLString: String,
        username: String,
        password: String,
    ) async -> Bool {
        guard let actor = await storytellerActor(for: sourceID) else { return false }
        return await actor.setLogin(baseURL: baseURLString, username: username, password: password)
    }

    public func createBookSource(_ configuration: BookSourceConfiguration) async
        -> BookSourceRecord?
    {
        await ensureSourceRegistryLoaded()

        let now = SilveranDate.isoTimestamp(from: Date())
        let sourceID = await sourceIDForNewSource(
            kind: configuration.kind,
            configuredPath: configuration.storagePath,
        )
        if sourceRecords.contains(where: { $0.id == sourceID }) {
            return nil
        }
        let storageURL = await storageURLForNewSource(
            kind: configuration.kind,
            sourceID: sourceID,
            configuredPath: configuration.storagePath,
        )
        let record = BookSourceRecord(
            id: sourceID,
            name: normalizedSourceName(
                configuration.name,
                fallback: configuration.kind.defaultName,
            ),
            kind: configuration.kind,
            capabilities: capabilities(for: configuration.kind),
            createdAt: now,
            updatedAt: now,
            storagePath: storageURL?.path,
            storageBookmarkData: configuration.storageBookmarkData,
        )

        switch configuration.kind {
            case .storyteller:
                guard
                    let serverURL = configuration.serverURL,
                    let username = configuration.username,
                    let password = configuration.password
                else {
                    return nil
                }
                let actor = StorytellerActor(sourceRecord: record)
                sourcesByID[record.id] = actor

                guard
                    await actor.configureCredentials(
                        baseURL: serverURL,
                        username: username,
                        password: password,
                    )
                else {
                    sourcesByID[record.id] = nil
                    return nil
                }

                do {
                    try await AuthenticationActor.shared.saveCredentials(
                        url: serverURL,
                        username: username,
                        password: password,
                        sourceID: record.id,
                    )
                } catch {
                    sourcesByID[record.id] = nil
                    return nil
                }
            case .localFolder:
                guard record.storagePath != nil else { return nil }
                if let storageURL {
                    try? await FilesystemActor.shared.ensureSourceIDMarker(
                        in: storageURL,
                        sourceID: record.id,
                    )
                }
                await closeFolderAccessIfNeeded(sourceID: record.id)
                sourcesByID[record.id] = FolderSourceActor(sourceRecord: record)
        }

        await upsertSourceRecord(record)
        return record
    }

    public func updateBookSource(
        id sourceID: BookSourceID,
        configuration: BookSourceConfiguration,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let existing = sourceRecords.first(where: { $0.id == sourceID }) else {
            return false
        }
        let kind = existing.kind

        let updatedRecord = BookSourceRecord(
            id: existing.id,
            name: normalizedSourceName(configuration.name, fallback: existing.name),
            kind: kind,
            capabilities: capabilities(for: kind),
            createdAt: existing.createdAt,
            updatedAt: SilveranDate.isoTimestamp(from: Date()),
            storagePath: updatedStoragePath(
                existing: existing,
                configuration: configuration,
            ),
            storageBookmarkData: updatedStorageBookmarkData(
                existing: existing,
                configuration: configuration,
            ),
        )

        switch kind {
            case .storyteller:
                guard
                    let serverURL = configuration.serverURL,
                    let username = configuration.username,
                    let password = configuration.password
                else {
                    return false
                }

                let actor: StorytellerActor
                if let existingActor = sourcesByID[sourceID] as? StorytellerActor {
                    actor = existingActor
                } else {
                    await closeFolderAccessIfNeeded(sourceID: sourceID)
                    actor = StorytellerActor(sourceRecord: updatedRecord)
                    sourcesByID[sourceID] = actor
                }

                guard
                    await actor.configureCredentials(
                        baseURL: serverURL,
                        username: username,
                        password: password,
                    )
                else {
                    return false
                }

                do {
                    try await AuthenticationActor.shared.saveCredentials(
                        url: serverURL,
                        username: username,
                        password: password,
                        sourceID: sourceID,
                    )
                } catch {
                    return false
                }

                await upsertSourceRecord(updatedRecord)
            case .localFolder:
                guard updatedRecord.storagePath != nil else { return false }
                if let storagePath = updatedRecord.storagePath {
                    let storageURL = URL(fileURLWithPath: storagePath, isDirectory: true)
                    if let marker = try? await FilesystemActor.shared.sourceIDMarker(
                        in: storageURL
                    ),
                        marker != sourceID
                    {
                        return false
                    }
                    try? await FilesystemActor.shared.ensureSourceIDMarker(
                        in: storageURL,
                        sourceID: sourceID,
                    )
                }
                await closeFolderAccessIfNeeded(sourceID: sourceID)
                sourcesByID[sourceID] = FolderSourceActor(sourceRecord: updatedRecord)
                await upsertSourceRecord(updatedRecord)
        }
        return true
    }

    public func testBookSourceConnection(sourceID: BookSourceID) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard
            sourceRecords.contains(where: { $0.id == sourceID }),
            let credentials = try? await AuthenticationActor.shared.loadCredentials(
                sourceID: sourceID
            ),
            let actor = await storytellerActor(for: sourceID)
        else {
            return false
        }

        return await actor.setLogin(
            baseURL: credentials.url,
            username: credentials.username,
            password: credentials.password,
        )
    }

    public func removeBookSource(
        id sourceID: BookSourceID,
        removeLocalData: Bool = true,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard sourceRecords.contains(where: { $0.id == sourceID }) else {
            return false
        }

        if let actor = sourcesByID[sourceID] as? StorytellerActor {
            _ = await actor.logout()
        }
        await closeFolderAccessIfNeeded(sourceID: sourceID)

        do {
            try await AuthenticationActor.shared.deleteCredentials(sourceID: sourceID)
            if removeLocalData {
                try await LocalMediaActor.shared.removeSourceCacheData(sourceID: sourceID)
            }
        } catch {
            return false
        }

        sourceRecords.removeAll { $0.id == sourceID }
        sourcesByID[sourceID] = nil

        try? await FilesystemActor.shared.saveBookSources(sourceRecords)
        await notifyLibraryObservers()
        return true
    }

    public func credentials(for sourceID: BookSourceID) async
        -> (url: String, username: String, password: String)?
    {
        try? await AuthenticationActor.shared.loadCredentials(sourceID: sourceID)
    }

    public func checkBookUpdatePermission(
        sourceID: BookSourceID? = nil
    ) async -> StorytellerActor.PermissionCheckResult {
        guard let storyteller = await storytellerActor(for: sourceID) else {
            return .error("Not connected to server")
        }
        return await storyteller.checkBookUpdatePermission()
    }

    public func reloadSourceRegistry() async {
        await SilveranMigrations.ensureMigrationsRan()
        await closeAllFolderAccess()
        sourcesByID.removeAll()
        sourceRegistryLoaded = false
        await ensureSourceRegistryLoaded()
        _ = await fetchLibraryInformation()
        await notifyLibraryObservers()
    }

    /// Cold-start library refresh. Unlike `reloadSourceRegistry`, this loads the registry in place
    /// rather than tearing it down and rebuilding, so a concurrent book restore resolving its local
    /// media is never momentarily left with an empty source table. The slow network listing
    /// (`fetchLibraryInformation`, a serial per-source fetch) lives here so it stays off the restore
    /// critical path.
    public func refreshLibraryFromSources() async {
        await ensureSourceRegistryLoaded()
        _ = await fetchLibraryInformation()
        await notifyLibraryObservers()
    }

    @discardableResult
    public func fetchLibraryInformation() async -> [BookMetadata]? {
        await ensureSourceRegistryLoaded()

        var metadata: [BookMetadata] = []
        var sawSource = false

        let loopStart = CFAbsoluteTimeGetCurrent()
        debugLog(
            "[ConnDiag] fetchLibraryInformation: serial loop over \(sourceRecords.count) sources start"
        )
        for record in sourceRecords {
            guard let source = sourcesByID[record.id] else { continue }
            sawSource = true

            let sourceStart = CFAbsoluteTimeGetCurrent()
            let sourceMetadataOptional = await source.fetchLibraryInformation()
            let sourceElapsed = (CFAbsoluteTimeGetCurrent() - sourceStart) * 1000
            debugLog(
                "[ConnDiag] fetchLibraryInformation: source='\(record.name)' kind=\(record.kind) elapsed=\(String(format: "%.0f", sourceElapsed))ms books=\(sourceMetadataOptional?.count ?? -1)"
            )
            guard let sourceMetadata = sourceMetadataOptional else {
                continue
            }

            let stamped = sourceMetadata.map { book in
                var stamped = book
                stamped.sourceID = stamped.sourceID ?? record.id
                stamped.source = stamped.source ?? record.name
                return stamped
            }
            metadata.append(contentsOf: stamped)
            if record.kind == .storyteller {
                try? await LocalMediaActor.shared.updateSourceCacheMetadata(
                    stamped,
                    replacingSourceID: record.id,
                )
            }
        }

        let loopElapsed = (CFAbsoluteTimeGetCurrent() - loopStart) * 1000
        debugLog(
            "[ConnDiag] fetchLibraryInformation: serial loop done total=\(String(format: "%.0f", loopElapsed))ms books=\(metadata.count)"
        )

        guard sawSource else { return nil }
        return metadata
    }

    @discardableResult
    public func fetchLibraryInformation(sourceID: BookSourceID) async -> [BookMetadata]? {
        await ensureSourceRegistryLoaded()
        guard let source = sourceActor(for: sourceID) else { return nil }
        guard let metadata = await source.fetchLibraryInformation() else { return nil }
        let sourceRecord = sourceRecords.first(where: { $0.id == sourceID })
        let stamped = metadata.map { book in
            var stamped = book
            stamped.sourceID = stamped.sourceID ?? sourceID
            stamped.source = stamped.source ?? sourceRecord?.name
            return stamped
        }
        if sourceRecord?.kind == .storyteller {
            try? await LocalMediaActor.shared.updateSourceCacheMetadata(
                stamped,
                replacingSourceID: sourceID,
            )
        }
        return stamped
    }

    public func refreshBookFromSource(
        bookID: String,
        sourceID: BookSourceID?,
        policy: BookRefreshPolicy = .refresh,
    ) async -> BookRefreshResult {
        await ensureSourceRegistryLoaded()
        debugLog(
            "[MetadataCoverRefresh] BSA refreshBookFromSource start bookID=\(bookID) sourceID=\(sourceID ?? "nil") policy=\(policy)"
        )
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            debugLog(
                "[MetadataCoverRefresh] BSA refreshBookFromSource missing source bookID=\(bookID) sourceID=\(sourceID ?? "nil")"
            )
            return BookRefreshResult(
                book: nil,
                source: .cache,
                error: "Book metadata is missing source ID.",
            )
        }

        let cachedBook = await cachedBookMetadata(bookID: bookID, sourceID: resolvedSourceID)
        debugLog(
            "[MetadataCoverRefresh] BSA cached book bookID=\(bookID) found=\(cachedBook != nil) cachedUpdatedAt=\(cachedBook?.updatedAt ?? "nil")"
        )
        guard policy != .cachedOnly else {
            return BookRefreshResult(book: cachedBook, source: .cache)
        }

        let sourceRecord = sourceRecords.first { $0.id == resolvedSourceID }
        if policy == .forceRefresh, let storyteller = source as? StorytellerActor {
            debugLog(
                "[MetadataCoverRefresh] BSA fetching Storyteller book details bookID=\(bookID) sourceID=\(resolvedSourceID)"
            )
            guard var refreshed = await storyteller.fetchBookDetails(for: bookID) else {
                debugLog(
                    "[MetadataCoverRefresh] BSA Storyteller book details failed bookID=\(bookID) returningCache=\(cachedBook != nil)"
                )
                return BookRefreshResult(
                    book: cachedBook,
                    source: .cache,
                    error: "Could not refresh book from Storyteller.",
                )
            }
            refreshed.sourceID = refreshed.sourceID ?? resolvedSourceID
            refreshed.source = refreshed.source ?? sourceRecord?.name

            debugLog(
                "[MetadataCoverRefresh] BSA replacing cached book metadata bookID=\(bookID) refreshedUpdatedAt=\(refreshed.updatedAt ?? "nil")"
            )
            // Atomic replace with a single observer notification. Removing the book
            // first would delete its downloaded media and strand cover states held by
            // views, and the intermediate notify defeats updatedAt change detection.
            try? await LocalMediaActor.shared.updateSourceCacheBookMetadata(
                refreshed,
                sourceID: resolvedSourceID,
            )
            debugLog(
                "[MetadataCoverRefresh] BSA force refresh complete bookID=\(bookID) refreshedUpdatedAt=\(refreshed.updatedAt ?? "nil")"
            )
            return BookRefreshResult(book: refreshed, source: .source)
        }

        debugLog(
            "[MetadataCoverRefresh] BSA fetching full source library bookID=\(bookID) sourceID=\(resolvedSourceID)"
        )
        guard let sourceMetadata = await fetchLibraryInformation(sourceID: resolvedSourceID),
            let refreshed = sourceMetadata.first(where: { $0.uuid == bookID })
        else {
            debugLog(
                "[MetadataCoverRefresh] BSA full source refresh failed bookID=\(bookID) returningCache=\(cachedBook != nil)"
            )
            return BookRefreshResult(
                book: cachedBook,
                source: .cache,
                error: "Could not refresh book from source.",
            )
        }

        debugLog(
            "[MetadataCoverRefresh] BSA full source refresh complete bookID=\(bookID) refreshedUpdatedAt=\(refreshed.updatedAt ?? "nil")"
        )
        return BookRefreshResult(book: refreshed, source: .source)
    }

    public func librarySnapshot(policy: LibrarySnapshotPolicy = .cachedOnly) async
        -> BookServiceLibrarySnapshot
    {
        await ensureSourceRegistryLoaded()

        switch policy {
            case .cachedOnly:
                return await cachedLibrarySnapshot()
            case .cachedThenRefresh:
                let snapshot = await cachedLibrarySnapshot()
                Task {
                    _ = await self.fetchLibraryInformation()
                    await self.notifyLibraryObservers()
                }
                return snapshot
            case .refresh:
                _ = await fetchLibraryInformation()
                return await cachedLibrarySnapshot()
        }
    }

    private func cachedLibrarySnapshot() async -> BookServiceLibrarySnapshot {
        let folderSourceIDs = Set(sourceRecords.filter { $0.kind == .localFolder }.map(\.id))
        let cachedMetadata = await LocalMediaActor.shared.libraryMetadata()
            .filter { book in
                guard let sourceID = book.sourceID else { return true }
                return !folderSourceIDs.contains(sourceID)
            }
        let metadata = cachedMetadata + (await cachedLocalFolderBooks())
        return BookServiceLibrarySnapshot(
            books: metadata,
            mediaPaths: await resolvedLocalMediaPaths(for: metadata),
            cachedMediaPaths: await LocalMediaActor.shared.cachedMediaPaths(for: cachedMetadata),
            sources: sourceRecords,
        )
    }

    private func cachedBookMetadata(
        bookID: String,
        sourceID: BookSourceID,
    ) async -> BookMetadata? {
        let folderSourceIDs = Set(sourceRecords.filter { $0.kind == .localFolder }.map(\.id))
        if folderSourceIDs.contains(sourceID) {
            return await localFolderBooks(sourceID: sourceID).first { $0.uuid == bookID }
        }
        return await LocalMediaActor.shared.libraryMetadata().first {
            $0.uuid == bookID && $0.sourceID == sourceID
        }
    }

    public func addLibraryCacheObserver(
        _ callback: @escaping @Sendable @MainActor () -> Void
    ) async -> UUID {
        let id = UUID()
        libraryObservers[id] = callback
        await ensureLocalMediaObserver()
        return id
    }

    public func scanLibraryCache() async throws {
        await LocalMediaActor.shared.reconcileDownloadedMedia()
    }

    public func updateLibraryCacheMetadata(
        _ metadata: [BookMetadata],
        replacingSourceID sourceID: BookSourceID? = nil,
    ) async throws {
        await ensureSourceRegistryLoaded()
        let folderSourceIDs = Set(sourceRecords.filter { $0.kind == .localFolder }.map(\.id))
        if let sourceID, folderSourceIDs.contains(sourceID) {
            await notifyLibraryObservers()
            return
        }
        let cacheableMetadata = metadata.filter { book in
            guard let sourceID = book.sourceID else { return true }
            return !folderSourceIDs.contains(sourceID)
        }
        try await LocalMediaActor.shared.updateSourceCacheMetadata(
            cacheableMetadata,
            replacingSourceID: sourceID,
        )
    }

    public func importDownloadedFileToCache(
        from tempURL: URL,
        metadata: BookMetadata,
        category: LocalMediaCategory,
        filename: String,
        audioIsPackage: Bool = true,
    ) async throws {
        try await LocalMediaActor.shared.importDownloadedFile(
            from: tempURL,
            metadata: metadata,
            category: category,
            filename: filename,
            audioIsPackage: audioIsPackage,
        )
    }

    public func localFolderBooks(sourceID: BookSourceID? = nil) async -> [BookMetadata] {
        await ensureSourceRegistryLoaded()
        let folderRecords =
            if let sourceID {
                sourceRecords.filter { $0.id == sourceID && $0.kind == .localFolder }
            } else {
                sourceRecords.filter { $0.kind == .localFolder }
            }

        var metadata: [BookMetadata] = []
        for record in folderRecords {
            guard let folder = sourceActor(for: record.id) as? FolderSourceActor else { continue }
            guard let sourceMetadata = await folder.fetchLibraryInformation() else { continue }
            let stamped = sourceMetadata.map { book in
                var stamped = book
                stamped.sourceID = stamped.sourceID ?? record.id
                stamped.source = stamped.source ?? record.name
                return stamped
            }
            metadata.append(contentsOf: stamped)
        }
        return metadata
    }

    public func cachedLocalFolderBooks(sourceID: BookSourceID? = nil) async -> [BookMetadata] {
        await ensureSourceRegistryLoaded()
        let folderRecords =
            if let sourceID {
                sourceRecords.filter { $0.id == sourceID && $0.kind == .localFolder }
            } else {
                sourceRecords.filter { $0.kind == .localFolder }
            }

        var metadata: [BookMetadata] = []
        for record in folderRecords {
            guard let folder = sourceActor(for: record.id) as? FolderSourceActor else { continue }
            let sourceMetadata = await folder.cachedLibraryInformation()
            let stamped = sourceMetadata.map { book in
                var stamped = book
                stamped.sourceID = stamped.sourceID ?? record.id
                stamped.source = stamped.source ?? record.name
                return stamped
            }
            metadata.append(contentsOf: stamped)
        }
        return metadata
    }

    public func localMediaDirectory(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async -> URL? {
        guard
            let media = await resolveLocalMedia(
                for: bookID,
                sourceID: sourceID,
                category: category,
            )
        else {
            return nil
        }
        return media.url.deletingLastPathComponent()
    }

    public func deleteCachedMedia(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async throws {
        await ensureSourceRegistryLoaded()
        let resolvedSourceID = resolveExplicitSourceID(sourceID)
        if let resolvedSourceID,
            sourceRecords.first(where: { $0.id == resolvedSourceID })?.kind == .localFolder
        {
            try await LocalMediaActor.shared.deleteMedia(
                for: bookID,
                category: category,
                sourceID: resolvedSourceID,
            )
            return
        }

        try await LocalMediaActor.shared.deleteMedia(
            for: bookID,
            category: category,
            sourceID: resolvedSourceID,
        )
    }

    public func fetchCoverImage(
        for bookId: String,
        sourceID: BookSourceID,
        audio: Bool = false,
        width: Int? = 209,
        height: Int? = 320,
        version: String? = nil,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil,
    ) async -> BookCover? {
        await ensureSourceRegistryLoaded()
        guard let source = sourceActor(for: sourceID) else { return nil }
        return await source.fetchCoverImage(
            for: bookId,
            audio: audio,
            width: width,
            height: height,
            version: version,
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince,
        )
    }

    private static func coverCacheVariant(audio: Bool) -> String {
        audio ? "audioSquare" : "standard"
    }

    public func cachedCoverData(for bookID: String, audio: Bool) async -> Data? {
        await FilesystemActor.shared.loadCoverImage(
            uuid: bookID,
            variant: Self.coverCacheVariant(audio: audio),
        )
    }

    // Cache policy for covers lives here, mirroring metadata: cachedThenFetch
    // serves the disk cache first (fast scroll), then falls back to the source;
    // forceRefresh bypasses the cache and asks the source directly. Persisting
    // fetched bytes is left to persistCachedCover so callers only cache
    // payloads that proved decodable.
    public func loadCover(
        for bookID: String,
        sourceID: BookSourceID?,
        audio: Bool,
        width: Int?,
        height: Int?,
        version: String?,
        allowNetwork: Bool,
        policy: CoverLoadPolicy,
    ) async -> CoverLoadResponse {
        if policy == .cachedThenFetch,
            let data = await cachedCoverData(for: bookID, audio: audio)
        {
            return .cached(data)
        }

        guard let sourceID else { return .missing }

        if policy == .cachedThenFetch, await sourceKind(for: sourceID) == .localFolder {
            guard
                let cover = await fetchCoverImage(
                    for: bookID,
                    sourceID: sourceID,
                    audio: false,
                    width: nil,
                    height: nil,
                    version: nil,
                )
            else {
                return .missing
            }
            return .fetched(cover)
        }

        guard allowNetwork else { return .skippedOffline }

        debugLog(
            "[MetadataCoverRefresh] BSA loadCover sized fetch bookID=\(bookID) sourceID=\(sourceID) audio=\(audio) size=\(width.map(String.init) ?? "nil")x\(height.map(String.init) ?? "nil") version=\(version ?? "nil") policy=\(policy)"
        )
        if let cover = await fetchCoverImage(
            for: bookID,
            sourceID: sourceID,
            audio: audio,
            width: width,
            height: height,
            version: version,
        ) {
            debugLog(
                "[MetadataCoverRefresh] BSA loadCover sized fetch success bookID=\(bookID) audio=\(audio) bytes=\(cover.data.count) etag=\(cover.etag ?? "nil") lastModified=\(cover.lastModified ?? "nil") cacheControl=\(cover.cacheControl ?? "nil")"
            )
            return .fetched(cover)
        }

        debugLog(
            "[MetadataCoverRefresh] BSA loadCover sized fetch nil, falling back raw bookID=\(bookID) audio=\(audio)"
        )
        if let cover = await fetchCoverImage(
            for: bookID,
            sourceID: sourceID,
            audio: audio,
            width: nil,
            height: nil,
        ) {
            debugLog(
                "[MetadataCoverRefresh] BSA loadCover raw fetch success bookID=\(bookID) audio=\(audio) bytes=\(cover.data.count) etag=\(cover.etag ?? "nil") lastModified=\(cover.lastModified ?? "nil") cacheControl=\(cover.cacheControl ?? "nil")"
            )
            return .fetched(cover)
        }

        debugLog(
            "[MetadataCoverRefresh] BSA loadCover raw fetch nil bookID=\(bookID) audio=\(audio)"
        )
        return .missing
    }

    public func persistCachedCover(bookID: String, audio: Bool, data: Data) async {
        try? await FilesystemActor.shared.saveCoverImage(
            uuid: bookID,
            data: data,
            variant: Self.coverCacheVariant(audio: audio),
        )
    }

    public func invalidateCachedCovers(for bookID: String) async throws {
        try await FilesystemActor.shared.removeCoverImages(uuid: bookID)
    }

    public func removeAllCachedCovers() async throws {
        try await FilesystemActor.shared.removeAllCoverImages()
    }

    func fetchBookDetails(for bookId: String, sourceID: BookSourceID?) async -> BookMetadata? {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        guard var book = await storyteller.fetchBookDetails(for: bookId) else { return nil }
        book.sourceID = book.sourceID ?? sourceID
        book.source = book.source ?? sourceRecords.first(where: { $0.id == sourceID })?.name
        return book
    }

    public func resolveLocalMedia(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async -> ResolvedLocalMedia? {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return nil
        }
        return await source.resolveLocalMedia(for: bookID, category: category)
    }

    /// Packages a book's local audiobook into a Readium `.audiobook` zip for the content server's
    /// download. Returns a temp file URL the caller is responsible for deleting after sending it.
    public func packageAudiobook(for bookID: String, sourceID: BookSourceID?) async -> URL? {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return nil
        }
        return await source.packageAudiobook(for: bookID)
    }

    public func resolvedLocalMediaPaths(for metadata: [BookMetadata]) async -> [String: MediaPaths]
    {
        await ensureSourceRegistryLoaded()
        let folderSourceIDs = Set(sourceRecords.filter { $0.kind == .localFolder }.map(\.id))

        var pathsByBookID = await LocalMediaActor.shared.cachedMediaPaths(for: metadata)

        for book in metadata {
            guard let sourceID = book.sourceID, folderSourceIDs.contains(sourceID) else { continue }
            var paths = pathsByBookID[book.uuid] ?? MediaPaths()
            if paths.ebookPath == nil,
                let ebook = await resolveLocalMedia(
                    for: book.uuid,
                    sourceID: sourceID,
                    category: .ebook,
                )
            {
                paths.ebookPath = ebook.url
            }
            if paths.audioPath == nil,
                let audio = await resolveLocalMedia(
                    for: book.uuid,
                    sourceID: sourceID,
                    category: .audio,
                )
            {
                paths.audioPath = audio.url
            }
            if paths.syncedPath == nil,
                let synced = await resolveLocalMedia(
                    for: book.uuid,
                    sourceID: sourceID,
                    category: .synced,
                )
            {
                paths.syncedPath = synced.url
            }
            if paths.ebookPath != nil || paths.audioPath != nil || paths.syncedPath != nil {
                pathsByBookID[book.uuid] = paths
            }
        }
        return pathsByBookID
    }

    public func prepareEbookForReading(
        bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async throws -> PreparedEbookMedia {
        guard
            let resolved = await resolveLocalMedia(
                for: bookID,
                sourceID: sourceID,
                category: category,
            )
        else {
            throw LocalMediaError.importFailed("Local EPUB media is unavailable.")
        }

        let readerURL = try await FilesystemActor.shared.prepareEpubForReading(
            epubPath: resolved.url,
            sourceID: resolved.sourceID,
            bookID: resolved.bookID,
            category: resolved.category,
        )

        return PreparedEbookMedia(
            bookID: resolved.bookID,
            sourceID: resolved.sourceID,
            category: resolved.category,
            originalURL: resolved.url,
            readerURL: readerURL,
            locationKind: resolved.kind,
        )
    }

    public func createAuthenticatedDownloadRequest(
        for bookId: String,
        sourceID: BookSourceID?,
        format: StorytellerBookFormat,
    ) async -> URLRequest? {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        return await storyteller.createAuthenticatedDownloadRequest(for: bookId, format: format)
    }

    public func updateBook(
        _ payload: StorytellerBookUpdatePayload,
        sourceID: BookSourceID? = nil,
        textCover: StorytellerCoverUpload? = nil,
        audioCover: StorytellerCoverUpload? = nil,
    ) async -> BookMetadata? {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID) else {
            return nil
        }
        guard let storyteller = sourceActor(for: resolvedSourceID) as? StorytellerActor else {
            lastUpdateErrorsBySourceID[resolvedSourceID] =
                "No Storyteller server is configured for this book."
            return nil
        }

        guard
            var metadata = await storyteller.updateBook(
                payload,
                textCover: textCover,
                audioCover: audioCover,
            )
        else {
            lastUpdateErrorsBySourceID[resolvedSourceID] =
                await storyteller.lastUpdateBookError ?? "Update failed"
            return nil
        }

        metadata.sourceID = resolvedSourceID
        lastUpdateErrorsBySourceID[resolvedSourceID] = nil

        debugLog(
            "[MetadataCoverRefresh] BSA updateBook success bookID=\(metadata.uuid) sourceID=\(resolvedSourceID) updatedAt=\(metadata.updatedAt ?? "nil")"
        )

        let refreshResult = await refreshBookFromSource(
            bookID: metadata.uuid,
            sourceID: resolvedSourceID,
            policy: .forceRefresh,
        )
        if let refreshed = refreshResult.book, refreshResult.source == .source {
            debugLog(
                "[MetadataCoverRefresh] BSA updateBook force refreshed bookID=\(refreshed.uuid) sourceID=\(resolvedSourceID) updatedAt=\(refreshed.updatedAt ?? "nil")"
            )
            return refreshed
        }

        debugLog(
            "[MetadataCoverRefresh] BSA updateBook force refresh failed; caching update response bookID=\(metadata.uuid) sourceID=\(resolvedSourceID) updatedAt=\(metadata.updatedAt ?? "nil") error=\(refreshResult.error ?? "nil")"
        )
        do {
            try await LocalMediaActor.shared.updateSourceCacheBookMetadata(
                metadata,
                sourceID: resolvedSourceID,
            )
        } catch {
            debugLog(
                "[MetadataCoverRefresh] BSA updateBook cache fallback write failed bookID=\(metadata.uuid) error=\(error)"
            )
        }
        return metadata
    }

    public func deleteBook(
        _ bookId: String,
        sourceID: BookSourceID? = nil,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return false
        }

        let success = await source.deleteBook(bookId)
        if success {
            await notifyLibraryObservers()
        }
        return success
    }

    public func deleteBookAsset(
        _ bookId: String,
        sourceID: BookSourceID? = nil,
        type: StorytellerBookFormat,
    ) async -> DeleteAssetResult {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return .failed
        }

        let result = await source.deleteAsset(bookId, category: localMediaCategory(for: type))
        if case .success = result {
            await notifyLibraryObservers()
        }
        return result
    }

    public func startAlignment(
        for bookId: String,
        sourceID: BookSourceID? = nil,
        restart: AlignmentRestartMode = .none,
    ) async -> Bool {
        guard let storyteller = await storytellerActor(for: sourceID) else { return false }
        return await storyteller.startAlignment(for: bookId, restart: restart)
    }

    public func cancelAlignment(for bookId: String, sourceID: BookSourceID? = nil) async -> Bool {
        guard let storyteller = await storytellerActor(for: sourceID) else { return false }
        return await storyteller.cancelAlignment(for: bookId)
    }

    public func upgradeEpub(for bookId: String, sourceID: BookSourceID? = nil) async -> Bool {
        guard let storyteller = await storytellerActor(for: sourceID) else { return false }
        return await storyteller.upgradeEpub(for: bookId)
    }

    public func uploadBookAssets(
        bookUUID: String,
        sourceID: BookSourceID? = nil,
        ebook: StorytellerUploadAsset? = nil,
        audiobook: StorytellerUploadAsset? = nil,
        audiobooks: [StorytellerUploadAsset] = [],
        readaloud: StorytellerUploadAsset? = nil,
        collectionUUID: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return false
        }

        let audiobookAssets = audiobooks + [audiobook].compactMap(\.self)
        let title =
            ebook?.filename
            ?? readaloud?.filename
            ?? audiobookAssets.first?.filename
            ?? "Book"
        let success = await source.acceptBook(
            bookUUID: bookUUID,
            title: title,
            ebook: ebook,
            audiobooks: audiobookAssets,
            readaloud: readaloud,
            collectionUUID: collectionUUID,
            onProgress: onProgress,
        )
        if success {
            await notifyLibraryObservers()
        }
        return success
    }

    public func replaceBookAsset(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        sourceID: BookSourceID? = nil,
        replaceMetadata: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> ReplaceAssetResult {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return .failed
        }

        let result = await source.replaceAsset(
            asset,
            bookID: bookUUID,
            replaceMetadata: replaceMetadata,
            onProgress: onProgress,
        )
        if case .success = result {
            await notifyLibraryObservers()
        }
        return result
    }

    private func localMediaCategory(for format: StorytellerBookFormat) -> LocalMediaCategory {
        switch format {
            case .ebook:
                return .ebook
            case .audiobook:
                return .audio
            case .readaloud:
                return .synced
        }
    }

    public func locallyAvailableMedia(
        for bookID: String,
        sourceID: BookSourceID?,
    ) async -> Set<LocalMediaCategory> {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return []
        }
        return await source.locallyAvailableMedia(for: bookID)
    }

    /// Copies a book between sources. The source actor exports its locally-available media and the
    /// destination accepts it; neither end's storage layout is visible here. The caller should ensure
    /// every existing category is downloaded first (see `locallyAvailableMedia`).
    public func copyBook(
        _ book: BookMetadata,
        to destinationSourceID: BookSourceID,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let destination = sourceActor(for: destinationSourceID) else {
            debugLog("[BookServiceActor] copyBook: unknown destination \(destinationSourceID)")
            return false
        }
        guard let source = sourceActor(for: book.sourceID) else {
            debugLog("[BookServiceActor] copyBook: unknown source for \(book.id)")
            return false
        }

        let available = await source.locallyAvailableMedia(for: book.id)
        guard requiredCategories(for: book).isSubset(of: available) else {
            debugLog("[BookServiceActor] copyBook: \(book.id) not fully downloaded at source")
            return false
        }

        guard let assets = await source.exportAssets(for: book.id) else {
            debugLog("[BookServiceActor] copyBook: source could not export \(book.id)")
            return false
        }

        let destinationBookID = UUID().uuidString
        let success = await destination.acceptBook(
            bookUUID: destinationBookID,
            title: book.title,
            ebook: assets.ebook,
            audiobooks: assets.audiobooks,
            readaloud: assets.readaloud,
            collectionUUID: nil,
            onProgress: onProgress,
        )
        guard success else { return false }

        // Carry reading progress across: read the source's locator and push it onto the new book id.
        // Best-effort: a progress-mirror failure does not undo the media copy.
        if let position = await source.fetchBookPosition(bookId: book.id),
            let locator = position.locator
        {
            let result = await destination.sendProgressToServer(
                bookId: destinationBookID,
                locator: locator,
                timestamp: position.timestamp ?? floor(Date().timeIntervalSince1970 * 1000),
            )
            if case .success = result {
            } else {
                debugLog(
                    "[BookServiceActor] copyBook: progress mirror failed for \(destinationBookID)"
                )
            }
        }

        await fetchLibraryInformation()
        await notifyLibraryObservers()
        return true
    }

    private func requiredCategories(for book: BookMetadata) -> Set<LocalMediaCategory> {
        var categories: Set<LocalMediaCategory> = []
        if book.hasAvailableEbook { categories.insert(.ebook) }
        if book.hasAvailableAudiobook { categories.insert(.audio) }
        if book.hasAvailableReadaloud { categories.insert(.synced) }
        return categories
    }

    public func getAvailableStatuses() async -> [BookStatus] {
        await ensureSourceRegistryLoaded()
        var statusesByKey: [String: BookStatus] = [:]
        for status in FolderSourceActor.availableStatuses {
            statusesByKey[status.uuid ?? status.name.lowercased()] = status
        }
        for storyteller in storytellerActors() {
            for status in await storyteller.getAvailableStatuses() {
                statusesByKey[status.uuid ?? status.name.lowercased()] = status
            }
        }
        return statusesByKey.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func getAvailableStatuses(sourceID: BookSourceID) async -> [BookStatus] {
        await ensureSourceRegistryLoaded()
        if let storyteller = sourceActor(for: sourceID) as? StorytellerActor {
            return await storyteller.getAvailableStatuses()
        }
        if sourceActor(for: sourceID) is FolderSourceActor {
            return FolderSourceActor.availableStatuses
        }
        return []
    }

    public func updateStatus(
        forBooks bookIds: [String],
        sourceID: BookSourceID?,
        toStatusNamed statusName: String,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return false
        }
        // Each source keeps its own cache consistent inside updateStatus, so a single observer
        // notification suffices; we never force a folder rescan here.
        let success = await source.updateStatus(forBooks: bookIds, toStatusNamed: statusName)
        if success {
            await notifyLibraryObservers()
        }
        return success
    }

    public func fetchCollections(sourceID: BookSourceID) async -> [StorytellerCollection]? {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        return await storyteller.fetchCollections()
    }

    public func createCollection(
        _ payload: StorytellerCollectionCreatePayload,
        sourceID: BookSourceID,
    ) async
        -> StorytellerCollection?
    {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        return await storyteller.createCollection(payload)
    }

    public func deleteCollection(uuid: String, sourceID: BookSourceID) async -> Bool {
        guard let storyteller = await storytellerActor(for: sourceID) else { return false }
        return await storyteller.deleteCollection(uuid: uuid)
    }

    public func sendProgressToServer(
        bookId: String,
        sourceID: BookSourceID,
        locator: BookLocator,
        timestamp: Double,
    ) async -> HTTPResult {
        await ensureSourceRegistryLoaded()
        guard let source = sourceActor(for: sourceID) else { return .noConnection }
        return await source.sendProgressToServer(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
        )
    }

    public func fetchBookPosition(
        bookId: String,
        sourceID: BookSourceID,
    ) async -> BookReadingPosition? {
        await ensureSourceRegistryLoaded()
        guard let source = sourceActor(for: sourceID) else { return nil }
        return await source.fetchBookPosition(bookId: bookId)
    }

    private func ensureSourceRegistryLoaded() async {
        await SilveranMigrations.ensureMigrationsRan()
        guard !sourceRegistryLoaded else { return }

        let loadedSources =
            (try? await FilesystemActor.shared.loadOrCreateBookSources())
            ?? []

        sourceRecords = loadedSources
        sourceRegistryLoaded = true

        for record in sourceRecords {
            switch record.kind {
                case .storyteller:
                    let actor: StorytellerActor
                    if let existing = sourcesByID[record.id] as? StorytellerActor {
                        actor = existing
                    } else {
                        actor = StorytellerActor(sourceRecord: record)
                        sourcesByID[record.id] = actor
                    }

                    if !(await actor.isConfigured),
                        let credentials = try? await AuthenticationActor.shared.loadCredentials(
                            sourceID: record.id
                        )
                    {
                        _ = await actor.configureCredentials(
                            baseURL: credentials.url,
                            username: credentials.username,
                            password: credentials.password,
                        )
                    }

                    sourcesByID[record.id] = actor
                case .localFolder:
                    if sourcesByID[record.id] as? FolderSourceActor == nil {
                        sourcesByID[record.id] = FolderSourceActor(sourceRecord: record)
                    }
            }
        }
    }

    private func storytellerActors() -> [StorytellerActor] {
        sourceRecords.compactMap { record in
            guard record.kind == .storyteller else { return nil }
            return sourcesByID[record.id] as? StorytellerActor
        }
    }

    private func upsertSourceRecord(_ record: BookSourceRecord) async {
        await ensureSourceRegistryLoaded()

        sourceRecords.replaceOrAppend(record)

        try? await FilesystemActor.shared.saveBookSources(sourceRecords)
        await notifyLibraryObservers()
    }

    private func normalizedSourceName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func capabilities(for kind: BookSourceKind) -> BookSourceCapabilities {
        switch kind {
            case .storyteller:
                return .storyteller
            case .localFolder:
                return .localFolder
        }
    }

    private func storageURLForNewSource(
        kind: BookSourceKind,
        sourceID: BookSourceID,
        configuredPath: String?,
    ) async -> URL? {
        switch kind {
            case .storyteller:
                return nil
            case .localFolder:
                if let configuredPath,
                    !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let url = URL(fileURLWithPath: configuredPath, isDirectory: true)
                    try? await FilesystemActor.shared.ensureDirectoryExists(at: url)
                    return url
                }
                return nil
        }
    }

    private func sourceIDForNewSource(
        kind: BookSourceKind,
        configuredPath: String?,
    ) async -> BookSourceID {
        guard kind == .localFolder,
            let configuredPath = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredPath.isEmpty
        else {
            return UUID().uuidString
        }
        let url = URL(fileURLWithPath: configuredPath, isDirectory: true)
        if let sourceID = try? await FilesystemActor.shared.sourceIDMarker(in: url),
            !sourceID.isEmpty
        {
            return sourceID
        }
        return UUID().uuidString
    }

    private func updatedStoragePath(
        existing: BookSourceRecord,
        configuration: BookSourceConfiguration,
    ) -> String? {
        switch existing.kind {
            case .storyteller:
                return existing.storagePath
            case .localFolder:
                let configuredPath = configuration.storagePath?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return configuredPath?.isEmpty == false ? configuredPath : existing.storagePath
        }
    }

    private func updatedStorageBookmarkData(
        existing: BookSourceRecord,
        configuration: BookSourceConfiguration,
    ) -> Data? {
        switch existing.kind {
            case .storyteller:
                return existing.storageBookmarkData
            case .localFolder:
                return configuration.storageBookmarkData ?? existing.storageBookmarkData
        }
    }

    public func sourceKind(for sourceID: BookSourceID?) async -> BookSourceKind? {
        await ensureSourceRegistryLoaded()
        guard let sourceID else { return nil }
        return sourceRecords.first(where: { $0.id == sourceID })?.kind
    }
}

extension Array where Element == BookSourceRecord {
    fileprivate mutating func replaceOrAppend(_ record: BookSourceRecord) {
        if let index = firstIndex(where: { $0.id == record.id }) {
            self[index] = record
        } else {
            append(record)
        }
    }
}
