import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@globalActor
public actor BookServiceActor {
    public static let shared = BookServiceActor()
    private static let folderSourceStatuses: [BookStatus] = [
        BookStatus(uuid: "folder-status-to-read", name: "To read", isDefault: true),
        BookStatus(uuid: "folder-status-reading", name: "Reading"),
        BookStatus(uuid: "folder-status-read", name: "Read"),
    ]

    private var sourceRecords: [BookSourceRecord]
    private var sourcesByID: [BookSourceID: any BookSourceActor]
    private var sourceRegistryLoaded = false
    private var lastUpdateErrorsBySourceID: [BookSourceID: String] = [:]
    private var libraryObservers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var localMediaObserverID: UUID?

    public init() {
        self.sourceRecords = []
        self.sourcesByID = [:]
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

    public var currentApiBaseURL: URL? {
        get async {
            await ensureSourceRegistryLoaded()
            for actor in storytellerActors() {
                if let baseURL = await actor.currentApiBaseURL {
                    return baseURL
                }
            }
            return nil
        }
    }

    public var currentAccessToken: String? {
        get async {
            await ensureSourceRegistryLoaded()
            for actor in storytellerActors() {
                if let accessToken = await actor.currentAccessToken {
                    return accessToken
                }
            }
            return nil
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

    public func appDidBecomeActive() async {
        await ensureSourceRegistryLoaded()
        for actor in storytellerActors() {
            await actor.appDidBecomeActive()
        }
    }

    public func appWillResignActive() async {
        await ensureSourceRegistryLoaded()
        for actor in storytellerActors() {
            await actor.appWillResignActive()
        }
    }

    public func setLastNetworkOpSucceeded(_ succeeded: Bool) async {
        await ensureSourceRegistryLoaded()
        for actor in storytellerActors() {
            await actor.setLastNetworkOpSucceeded(succeeded)
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

        let now = ISO8601DateFormatter().string(from: Date())
        let sourceID = await sourceIDForNewSource(kind: configuration.kind, configuredPath: configuration.storagePath)
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
            name: normalizedSourceName(configuration.name, fallback: configuration.kind.defaultName),
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

                guard await actor.configureCredentials(
                    baseURL: serverURL,
                    username: username,
                    password: password,
                ) else {
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
            updatedAt: ISO8601DateFormatter().string(from: Date()),
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

                guard await actor.configureCredentials(
                    baseURL: serverURL,
                    username: username,
                    password: password,
                ) else {
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
                    if let marker = try? await FilesystemActor.shared.sourceIDMarker(in: storageURL),
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
                await notifyLibraryObservers()
        }
        return true
    }

    public func testBookSourceConnection(sourceID: BookSourceID) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard
            sourceRecords.contains(where: { $0.id == sourceID }),
            let credentials = try? await AuthenticationActor.shared.loadCredentials(sourceID: sourceID),
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
        return true
    }

    public func credentials(for sourceID: BookSourceID) async
        -> (url: String, username: String, password: String)?
    {
        try? await AuthenticationActor.shared.loadCredentials(sourceID: sourceID)
    }

    public func checkBookUpdatePermission(
        sourceID: BookSourceID? = nil,
    ) async -> StorytellerActor.PermissionCheckResult {
        guard let storyteller = await storytellerActor(for: sourceID) else {
            return .error("Not connected to server")
        }
        return await storyteller.checkBookUpdatePermission()
    }

    public func registerSourceActor(_ source: any BookSourceActor) async {
        let record = await source.sourceRecord
        await closeFolderAccessIfNeeded(sourceID: record.id)
        sourcesByID[record.id] = source
        await upsertSourceRecord(record)
    }

    public func reloadSourceRegistry() async {
        await SilveranMigrations.ensureMigrationsRan()
        await closeAllFolderAccess()
        sourcesByID.removeAll()
        sourceRegistryLoaded = false
        await ensureSourceRegistryLoaded()
    }

    @discardableResult
    public func fetchLibraryInformation() async -> [BookMetadata]? {
        await ensureSourceRegistryLoaded()

        var metadata: [BookMetadata] = []
        var sawSource = false

        for record in sourceRecords {
            guard let source = sourcesByID[record.id] else { continue }
            sawSource = true

            guard let sourceMetadata = await source.fetchLibraryInformation() else {
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
        let metadata = cachedMetadata + (await localFolderBooks())
        return BookServiceLibrarySnapshot(
            books: metadata,
            mediaPaths: await resolvedLocalMediaPaths(for: metadata),
            cachedMediaPaths: await LocalMediaActor.shared.cachedMediaPaths(for: cachedMetadata),
            sources: sourceRecords,
        )
    }

    public func addLibraryCacheObserver(
        _ callback: @escaping @Sendable @MainActor () -> Void,
    ) async -> UUID {
        let id = UUID()
        libraryObservers[id] = callback
        await ensureLocalMediaObserver()
        return id
    }

    public func removeLibraryCacheObserver(id: UUID) async {
        libraryObservers.removeValue(forKey: id)
    }

    public func scanLibraryCache() async throws {
        try await LocalMediaActor.shared.scanForMedia()
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

    public func folderSourceDirectory(sourceID: BookSourceID? = nil) async throws -> URL {
        guard let folder = await folderSourceActor(for: sourceID) else {
            throw LocalMediaError.importFailed("Folder source is not configured")
        }
        return try await folder.folderDirectory()
    }

    @discardableResult
    public func importMediaIntoFolderSource(
        from sourceFileURL: URL,
        category: LocalMediaCategory,
        bookName: String,
        bookUUID: String? = nil,
        sourceID: BookSourceID? = nil,
    ) async throws -> URL {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveFolderSourceID(sourceID),
            let folder = await folderSourceActor(for: resolvedSourceID)
        else {
            throw LocalMediaError.importFailed("Folder source is not configured")
        }

        let url = try await folder.importMedia(
            from: sourceFileURL,
            category: category,
            bookName: bookName,
            bookUUID: bookUUID,
        )
        await notifyLibraryObservers()
        return url
    }

    @discardableResult
    public func importAudiobookFilesIntoFolderSource(
        from sourceFileURLs: [URL],
        bookName: String,
        bookUUID: String? = nil,
        sourceID: BookSourceID? = nil,
    ) async throws -> URL {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveFolderSourceID(sourceID),
            let folder = await folderSourceActor(for: resolvedSourceID)
        else {
            throw LocalMediaError.importFailed("Folder source is not configured")
        }

        let url = try await folder.importAudiobookFiles(
            from: sourceFileURLs,
            bookName: bookName,
            bookUUID: bookUUID,
        )
        await notifyLibraryObservers()
        return url
    }

    public func localMediaDirectory(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async -> URL? {
        guard let media = await resolveLocalMedia(
            for: bookID,
            sourceID: sourceID,
            category: category,
        ) else {
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

    func fetchBook(
        for bookId: String,
        sourceID: BookSourceID,
        format: StorytellerBookFormat,
    ) async -> StorytellerBookDownload? {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        return await storyteller.fetchBook(for: bookId, format: format)
    }

    func fetchBookDetails(for bookId: String, sourceID: BookSourceID?) async -> BookMetadata? {
        guard let storyteller = await storytellerActor(for: sourceID) else { return nil }
        return await storyteller.fetchBookDetails(for: bookId)
    }

    public func resolveLocalMedia(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async -> ResolvedLocalMedia? {
        await ensureSourceRegistryLoaded()
        let resolvedSourceID = resolveExplicitSourceID(sourceID)

        if let cachedURL = await LocalMediaActor.shared.mediaFilePath(
            for: bookID,
            category: category,
            sourceID: resolvedSourceID,
        ), let resolvedSourceID {
            return ResolvedLocalMedia(
                bookID: bookID,
                sourceID: resolvedSourceID,
                category: category,
                url: cachedURL,
                kind: .cached,
            )
        }

        guard let resolvedSourceID,
            let folder = sourceActor(for: resolvedSourceID) as? FolderSourceActor
        else {
            return nil
        }
        return await folder.localMediaReference(for: bookID, category: category)
    }

    public func resolvedLocalMediaPaths(for metadata: [BookMetadata]) async -> [String: MediaPaths] {
        await ensureSourceRegistryLoaded()
        var pathsByBookID: [String: MediaPaths] = [:]
        for book in metadata {
            var paths = MediaPaths()
            if let ebook = await resolveLocalMedia(
                for: book.uuid,
                sourceID: book.sourceID,
                category: .ebook,
            ) {
                paths.ebookPath = ebook.url
            }
            if let audio = await resolveLocalMedia(
                for: book.uuid,
                sourceID: book.sourceID,
                category: .audio,
            ) {
                paths.audioPath = audio.url
            }
            if let synced = await resolveLocalMedia(
                for: book.uuid,
                sourceID: book.sourceID,
                category: .synced,
            ) {
                paths.syncedPath = synced.url
            }
            if paths.ebookPath != nil || paths.audioPath != nil || paths.syncedPath != nil {
                pathsByBookID[book.uuid] = paths
            }
        }
        return pathsByBookID
    }

    public func ensureLocalMediaAvailable(
        for bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
    ) async -> LocalMediaAvailability {
        if let media = await resolveLocalMedia(
            for: bookID,
            sourceID: sourceID,
            category: category,
        ) {
            return .available(media)
        }

        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return .missing
        }

        if source is FolderSourceActor {
            return .missing
        }

        switch await source.connectionStatus {
            case .connected:
                return .missing
            case .connecting, .disconnected, .error:
                return .offline
        }
    }

    public func prepareEbookForReading(
        bookID: String,
        sourceID: BookSourceID?,
        category: LocalMediaCategory,
        forceExtract: Bool = false,
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

        let prepared = try await FilesystemActor.shared.prepareEpubForReading(
            epubPath: resolved.url,
            sourceID: resolved.sourceID,
            bookID: resolved.bookID,
            category: resolved.category,
            forceExtract: forceExtract,
        )

        return PreparedEbookMedia(
            bookID: resolved.bookID,
            sourceID: resolved.sourceID,
            category: resolved.category,
            originalURL: resolved.url,
            readerURL: prepared.url,
            locationKind: resolved.kind,
            isExtracted: prepared.isExtracted,
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

        guard var metadata = await storyteller.updateBook(
            payload,
            textCover: textCover,
            audioCover: audioCover,
        ) else {
            lastUpdateErrorsBySourceID[resolvedSourceID] =
                await storyteller.lastUpdateBookError ?? "Update failed"
            return nil
        }

        let sourceRecord = sourceRecords.first { $0.id == resolvedSourceID }
        metadata.sourceID = resolvedSourceID
        metadata.source = sourceRecord?.name ?? metadata.source
        lastUpdateErrorsBySourceID[resolvedSourceID] = nil
        return metadata
    }

    public func deleteBook(
        _ bookId: String,
        sourceID: BookSourceID? = nil,
        includeAssets option: StorytellerIncludeAssetsOption? = nil,
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return false
        }

        switch sourceRecords.first(where: { $0.id == resolvedSourceID })?.kind {
            case .storyteller:
                guard let storyteller = source as? StorytellerActor else { return false }
                return await storyteller.deleteBook(bookId, includeAssets: option)
            case .localFolder:
                guard let folder = source as? FolderSourceActor else { return false }
                do {
                    try await folder.deleteBook(bookId)
                    await notifyLibraryObservers()
                    return true
                } catch {
                    return false
                }
            case nil:
                return false
        }
    }

    public func deleteBookAsset(
        _ bookId: String,
        sourceID: BookSourceID? = nil,
        type: StorytellerBookFormat,
    ) async -> StorytellerActor.DeleteAssetResult {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return .failed
        }

        switch sourceRecords.first(where: { $0.id == resolvedSourceID })?.kind {
            case .storyteller:
                guard let storyteller = source as? StorytellerActor else { return .failed }
                let result = await storyteller.deleteBookAsset(bookId, type: type)
                if case .success = result {
                    try? await LocalMediaActor.shared.deleteMedia(
                        for: bookId,
                        category: localMediaCategory(for: type),
                        sourceID: resolvedSourceID,
                    )
                }
                return result
            case .localFolder:
                guard let folder = source as? FolderSourceActor else { return .failed }
                do {
                    let previousMetadata = await folder.fetchLibraryInformation()?
                        .first(where: { $0.uuid == bookId })
                    try await folder.deleteMedia(bookId, category: localMediaCategory(for: type))
                    await notifyLibraryObservers()
                    if let updated = await folder.fetchLibraryInformation()?
                        .first(where: { $0.uuid == bookId })
                    {
                        return .success(updated)
                    }
                    if let previousMetadata {
                        return .success(previousMetadata)
                    }
                    return .failed
                } catch {
                    debugLog("[BookServiceActor] Failed to delete folder source asset: \(error)")
                    return .failed
                }
            case nil:
                return .failed
        }
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
    ) async -> Bool {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return false
        }

        switch sourceRecords.first(where: { $0.id == resolvedSourceID })?.kind {
            case .storyteller:
                guard let storyteller = source as? StorytellerActor else { return false }
                return await storyteller.uploadBookAssets(
                    bookUUID: bookUUID,
                    ebook: ebook,
                    audiobook: audiobook,
                    audiobooks: audiobooks,
                    readaloud: readaloud,
                    collectionUUID: collectionUUID,
                )
            case .localFolder:
                guard let folder = source as? FolderSourceActor else { return false }
                return await importAssetsToFolderSource(
                    folder,
                    bookUUID: bookUUID,
                    ebook: ebook,
                    audiobook: audiobook,
                    audiobooks: audiobooks,
                    readaloud: readaloud,
                    sourceID: resolvedSourceID,
                )
            case nil:
                return false
        }
    }

    public func replaceBookAsset(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        sourceID: BookSourceID? = nil,
        replaceMetadata: Bool = false,
    ) async -> StorytellerActor.ReplaceAssetResult {
        await ensureSourceRegistryLoaded()
        guard let resolvedSourceID = resolveExplicitSourceID(sourceID),
            let source = sourceActor(for: resolvedSourceID)
        else {
            return .failed
        }

        switch sourceRecords.first(where: { $0.id == resolvedSourceID })?.kind {
            case .storyteller:
                guard let storyteller = source as? StorytellerActor else { return .failed }
                let result = await storyteller.replaceBookAsset(
                    asset,
                    bookUUID: bookUUID,
                    replaceMetadata: replaceMetadata,
                )
                if case .success = result {
                    try? await LocalMediaActor.shared.deleteMedia(
                        for: bookUUID,
                        category: localMediaCategory(for: asset.format),
                        sourceID: resolvedSourceID,
                    )
                }
                return result
            case .localFolder:
                guard let folder = source as? FolderSourceActor else { return .failed }
                do {
                    try await folder.replaceAsset(
                        asset,
                        bookName: asset.filename,
                        bookUUID: bookUUID,
                    )
                    await notifyLibraryObservers()
                    return .success
                } catch {
                    debugLog("[BookServiceActor] Failed to replace folder source asset: \(error)")
                    return .failed
                }
            case nil:
                return .failed
        }
    }

    private func importAssetsToFolderSource(
        _ folder: FolderSourceActor,
        bookUUID: String,
        ebook: StorytellerUploadAsset?,
        audiobook: StorytellerUploadAsset?,
        audiobooks: [StorytellerUploadAsset],
        readaloud: StorytellerUploadAsset?,
        sourceID: BookSourceID,
    ) async -> Bool {
        let audiobookAssets = audiobooks + [audiobook].compactMap(\.self)
        guard ebook != nil || !audiobookAssets.isEmpty || readaloud != nil else { return false }

        do {
            try await folder.importBookAssets(
                bookUUID: bookUUID,
                bookName: ebook?.filename
                    ?? readaloud?.filename
                    ?? audiobookAssets.first?.filename
                    ?? "Book",
                ebook: ebook,
                audiobooks: audiobookAssets,
                readaloud: readaloud,
            )
            await notifyLibraryObservers()
            return true
        } catch {
            debugLog("[BookServiceActor] Failed to import assets to folder source: \(error)")
            return false
        }
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

    private func defaultExtension(for asset: StorytellerUploadAsset) -> String {
        switch asset.format {
            case .ebook, .readaloud:
                return "epub"
            case .audiobook:
                return asset.contentType == "audio/mp4" ? "m4b" : "mp3"
        }
    }

    public func getAvailableStatuses() async -> [BookStatus] {
        await ensureSourceRegistryLoaded()
        var statusesByKey: [String: BookStatus] = [:]
        for status in Self.folderSourceStatuses {
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
            return Self.folderSourceStatuses
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
        if let folder = source as? FolderSourceActor {
            guard
                let status = Self.folderSourceStatuses.first(where: {
                    $0.name.caseInsensitiveCompare(statusName) == .orderedSame
                })
            else {
                return false
            }
            let success = await folder.updateStatus(
                forBooks: bookIds,
                to: status,
            )
            if success {
                await notifyLibraryObservers()
            }
            return success
        }
        guard let storyteller = source as? StorytellerActor else { return false }
        let success = await storyteller.updateStatus(forBooks: bookIds, toStatusNamed: statusName)
        if success {
            _ = await fetchLibraryInformation(sourceID: resolvedSourceID)
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

    public func logout() async -> Bool {
        await ensureSourceRegistryLoaded()
        var didLogout = false
        for storyteller in storytellerActors() {
            didLogout = await storyteller.logout() || didLogout
        }
        return didLogout
    }

    public func logout(sourceID: BookSourceID) async -> Bool {
        guard let storyteller = await storytellerActor(for: sourceID) else { return false }
        return await storyteller.logout()
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
                            sourceID: record.id,
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
