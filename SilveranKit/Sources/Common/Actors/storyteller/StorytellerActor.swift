import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

public enum HTTPResult: Sendable {
    case success
    case failure
    case noConnection
}

@globalActor
public actor StorytellerActor {

    public static let shared = StorytellerActor()
    private var observers: (@Sendable @MainActor () -> Void)? = nil

    private var username: String?
    private var password: String?
    private var apiBaseURL: URL?
    private var accessToken: AccessToken?
    private(set) public var libraryMetadata: [BookMetadata] = []
    private var cachedStatuses: [BookStatus] = []
    public private(set) var connectionStatus: ConnectionStatus = .disconnected

    public var isConfigured: Bool {
        apiBaseURL != nil && username != nil && password != nil
    }

    public var currentApiBaseURL: URL? {
        apiBaseURL
    }

    public var currentAccessToken: String? {
        accessToken?.accessToken
    }

    private let urlSession: URLSession
    private let downloadDelegate: StorytellerDownloadDelegate
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Make authentication non-reentrant
    private var authenticationTask: Task<Bool, Never>? = nil

    private var monitoringTask: Task<Void, Never>? = nil
    public private(set) var lastNetworkOpSucceeded: Bool? = nil

    public init(
        session: URLSession? = nil
    ) {
        let delegate = StorytellerDownloadDelegate()
        let configuration: URLSessionConfiguration = {
            if let session {
                return session.configuration
            }
            return URLSessionConfiguration.default
        }()
        configuration.urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 0,
            diskPath: nil
        )
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10

        urlSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        downloadDelegate = delegate
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    public func request_notify(callback: @Sendable @MainActor @escaping () -> Void) {
        self.observers = callback
    }

    private func updateConnectionStatus(_ status: ConnectionStatus) async {
        let wasNotConnected = connectionStatus != .connected
        debugLog(
            "[StorytellerActor] updateConnectionStatus: \(connectionStatus) -> \(status), wasNotConnected: \(wasNotConnected)"
        )
        connectionStatus = status
        await observers?()

        if wasNotConnected && status == .connected {
            debugLog("[StorytellerActor] Connection restored, syncing pending progress queue")
            let (synced, failed) = await ProgressSyncActor.shared.syncPendingQueue()
            debugLog("[StorytellerActor] Pending queue sync: synced=\(synced), failed=\(failed)")
        }
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))

                guard !Task.isCancelled else { break }

                await self.checkConnection()
            }
        }
    }

    public func setLastNetworkOpSucceeded(_ succeeded: Bool) {
        lastNetworkOpSucceeded = succeeded
        Task { await observers?() }
    }

    private func checkConnection(force: Bool = false) async {
        guard username != nil, password != nil, apiBaseURL != nil else {
            await updateConnectionStatus(.disconnected)
            return
        }

        if !force && connectionStatus == .connected {
            return
        }

        await updateConnectionStatus(.connecting)

        if await ensureAuthentication() != nil {
            await updateConnectionStatus(.connected)
            let _ = await fetchLibraryInformation()
        } else {
            await updateConnectionStatus(.error("Connection check failed"))
        }
    }

    public func setLogin(
        baseURL baseURLString: String,
        username: String,
        password: String,
    ) async -> Bool {
        self.username = username
        self.password = password
        self.accessToken = nil
        guard let baseURL = URL(string: baseURLString) else {
            debugLog("[StorytellerActor] Invalid base URL: \(baseURLString)")
            await updateConnectionStatus(.error("Invalid server URL"))
            return false
        }
        apiBaseURL = StorytellerActor.resolveAPIBaseURL(from: baseURL)

        await updateConnectionStatus(.connecting)
        let success = await ensureAuthentication() != nil

        if success {
            await updateConnectionStatus(.connected)
            let _ = await fetchLibraryInformation()
        }

        startMonitoring()
        return success
    }

    /// Calls Storyteller's `/api/v2/token` endpoint to exchange credentials for a bearer token.
    /// Server implementation: `storyteller/web/src/app/api/v2/token/route.ts`.
    /// If successful, token will be stored on instance for future methods.
    @discardableResult
    func authenticate() async -> Bool {
        guard let apiBaseURL = apiBaseURL,
            let password = password,
            let username = username
        else {
            return false
        }
        /// Don't duplicate auth requests to server if one is already pending
        if let task = authenticationTask {
            return await task.value
        }

        let task = Task {
            authenticationTask = nil
            defer { authenticationTask = nil }
            do {
                let tokenURL = apiBaseURL.appendingPathComponent("token")

                let response = try await httpPost(
                    tokenURL.absoluteString,
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                        "Accept": "application/json",
                    ],
                    formParameters: [
                        "usernameOrEmail": username,
                        "password": password,
                    ],
                    session: urlSession
                )

                self.accessToken = try decoder.decode(AccessToken.self, from: response.data)
                return true
            } catch let error as HTTPRequestError {
                logStorytellerError("authenticate", error: error)
                switch error {
                    case .unauthorized:
                        await updateConnectionStatus(.error("Invalid credentials"))
                    default:
                        await updateConnectionStatus(.error("Connection failed"))
                }
                return false
            } catch let error as URLError {
                logStorytellerError("authenticate", error: error)
                await updateConnectionStatus(.error("Connection failed"))
                return false
            } catch {
                logStorytellerError("authenticate", error: error)
                await updateConnectionStatus(.error("Connection failed"))
                return false
            }
        }
        authenticationTask = task
        return await task.value
    }

    @discardableResult
    private func ensureAuthentication(forceReauth: Bool = false) async -> (URL, AccessToken)? {
        if forceReauth {
            // TODO: implement this.
            return nil
        }
        if let accessToken = accessToken, let apiBaseURL = apiBaseURL {
            return (apiBaseURL, accessToken)
        }
        if await authenticate(), let accessToken = accessToken, let apiBaseURL = apiBaseURL {
            return (apiBaseURL, accessToken)
        }
        debugLog("[StorytellerActor] Missing authentication and automatic login failed.")
        return nil
    }

    /// Fetches library metadata from `/api/v2/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/route.ts`.
    public func fetchLibraryInformation() async -> [BookMetadata]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let booksURL = baseURL.appendingPathComponent("books")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                booksURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchLibraryInformation",
                    context: "library listing"
                )
            else {
                return nil
            }

            do {
                let wrapper = try decoder.decode(
                    LenientArrayWrapper<BookMetadata>.self,
                    from: response.data
                )
                libraryMetadata = wrapper.values

                if let jsonArray = try? JSONSerialization.jsonObject(with: response.data) as? [Any]
                {
                    let totalCount = jsonArray.count
                    if totalCount > libraryMetadata.count {
                        let skipped = totalCount - libraryMetadata.count
                        debugLog(
                            "[StorytellerActor] WARNING: Skipped \(skipped) book(s) due to decode errors (loaded \(libraryMetadata.count)/\(totalCount))"
                        )
                    }
                }
            } catch {
                debugLog("[StorytellerActor] DECODE ERROR in fetchLibraryInformation:")
                debugLog("[StorytellerActor] Error: \(error)")
                if let decodingError = error as? DecodingError {
                    logDetailedDecodingError(decodingError, data: response.data)
                }
                throw error
            }

            try? await LocalMediaActor.shared.updateStorytellerMetadata(libraryMetadata)

            lastNetworkOpSucceeded = true
            await observers?()
            return libraryMetadata
        } catch {
            logStorytellerError("fetchLibraryInformation", error: error)
            return nil
        }
    }

    /// Downloads the cover image from `/api/v2/books/{bookId}/cover`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/cover/route.ts`.
    /// Returns `nil` when the server responds with 304 (Not Modified) or 404 (no cover available).
    public func fetchCoverImage(
        for bookId: String,
        audio: Bool = false,
        // Hard-code sizes. Storyteller server current returns 404 if you give no dimensions for non-readaloud books--a bug?
        width: Int? = 209,
        height: Int? = 320,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil,
    ) async -> BookCover? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let coverURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("cover")

        var queryParameters: [String: String] = [:]
        if let width {
            queryParameters["w"] = String(width)
        }
        if let height {
            queryParameters["h"] = String(height)
        }
        if audio {
            queryParameters["audio"] = "true"
        }

        var headers: [String: String] = [
            "Accept": "image/*",
            "Authorization": authorizationHeaderValue(for: token),
        ]
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        if let ifModifiedSince {
            headers["If-Modified-Since"] = ifModifiedSince
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(304)
        allowedStatuses.insert(404)

        do {
            let response = try await httpGet(
                coverURL.absoluteString,
                headers: headers,
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCoverImage",
                    context: "cover for \(bookId)"
                )
            else {
                return nil
            }

            let httpResponse = response.response
            return BookCover(
                data: response.data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                etag: httpResponse.value(forHTTPHeaderField: "Etag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
                cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control"),
                contentDisposition: httpResponse.value(
                    forHTTPHeaderField: "Content-Disposition"
                )
            )
        } catch {
            logStorytellerError("fetchCoverImage", error: error)
            return nil
        }
    }

    /// Streams the actual book from `/api/v2/books/{bookId}/files`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/files/route.ts`.
    func fetchBook(
        for bookId: String,
        format: StorytellerBookFormat
    ) async -> StorytellerBookDownload? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let fileURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("files")

        do {
            let requestURL = try urlWithQueryParameters(
                fileURL,
                queryParameters: ["format": format.rawValue]
            )

            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue(
                authorizationHeaderValue(for: token),
                forHTTPHeaderField: "Authorization"
            )

            let downloadTask = urlSession.downloadTask(with: request)
            let fallbackFilename = fallbackFilename(for: bookId, format: format)

            let events = AsyncThrowingStream<StorytellerDownloadEvent, Error> { continuation in
                let failureHandler: @Sendable (StorytellerDownloadFailure) -> Void = {
                    [weak self] failure in
                    guard let self else { return }
                    Task {
                        await self.handleDownloadFailure(failure, bookId: bookId)
                    }
                }

                downloadDelegate.register(
                    task: downloadTask,
                    state: StorytellerDownloadDelegate.TaskState(
                        continuation: continuation,
                        fallbackFilename: fallbackFilename,
                        bookId: bookId,
                        format: format,
                        failureHandler: failureHandler
                    )
                )

                continuation.onTermination = { @Sendable _ in
                    downloadTask.cancel()
                }

                downloadTask.resume()
            }

            return StorytellerBookDownload(
                initialFilename: fallbackFilename,
                events: events,
                cancel: { downloadTask.cancel() }
            )
        } catch {
            logStorytellerError("fetchBook", error: error)
            return nil
        }
    }

    private func handleDownloadFailure(
        _ failure: StorytellerDownloadFailure,
        bookId: String
    ) async {
        switch failure {
            case .nonHTTPResponse:
                debugLog("[StorytellerActor] fetchBook received non-HTTP response.")
            case .unauthorized:
                debugLog("[StorytellerActor] fetchBook unauthorized for \(bookId).")
                accessToken = nil
                await updateConnectionStatus(.error("Unauthorized"))
            case .notFound:
                debugLog("[StorytellerActor] fetchBook asset not found for \(bookId).")
            case .unexpectedStatus(let status):
                debugLog("[StorytellerActor] fetchBook unexpected status \(status) for \(bookId).")
        }
    }

    /// Fetches detailed metadata for a single book via `/api/v2/books/{bookId}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (GET handler).
    func fetchBookDetails(for bookId: String) async -> BookMetadata? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let bookURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                bookURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchBookDetails",
                    context: "book detail \(bookId)"
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(BookMetadata.self, from: response.data)
            } catch {
                debugLog("[StorytellerActor] DECODE ERROR in fetchBookDetails for book \(bookId):")
                debugLog("[StorytellerActor] Error: \(error)")
                if let decodingError = error as? DecodingError {
                    logDetailedDecodingError(decodingError, data: response.data)
                }
                throw error
            }
        } catch {
            logStorytellerError("fetchBookDetails", error: error)
            return nil
        }
    }

    /// Updates book metadata using the multipart protocol handled at `/api/v2/books/{bookId}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (PUT handler).
    /// TODO: UNTESTED
    func updateBook(
        _ payload: StorytellerBookUpdatePayload,
        textCover: StorytellerCoverUpload? = nil,
        audioCover: StorytellerCoverUpload? = nil,
    ) async -> BookMetadata? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let updateURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(payload.uuid)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        var fieldOrder: [String] = []
        var formEntries: [(name: String, value: String)] = []
        var fileEntries: [(name: String, upload: StorytellerCoverUpload)] = []

        // Bug in swift compiler requires non-isolated (local isolation cannot validate)
        nonisolated func registerField(_ name: String) {
            if !fieldOrder.contains(name) {
                fieldOrder.append(name)
            }
        }

        func appendJSONField<T: Encodable>(_ name: String, value: T?) -> Bool {
            registerField(name)
            guard let fragment = jsonFragment(from: value) else {
                debugLog("[StorytellerActor] updateBook failed to encode field \(name).")
                return false
            }
            formEntries.append((name, fragment))
            return true
        }

        if let title = payload.title {
            guard appendJSONField("title", value: title) else { return nil }
        }

        if let subtitle = payload.subtitle {
            guard appendJSONField("subtitle", value: subtitle) else { return nil }
        }

        if let language = payload.language {
            guard appendJSONField("language", value: language) else { return nil }
        }

        if let publicationDate = payload.publicationDate {
            guard appendJSONField("publicationDate", value: publicationDate) else { return nil }
        }

        if let descriptionWrapper = payload.description {
            guard appendJSONField("description", value: descriptionWrapper) else { return nil }
        }

        if let ratingWrapper = payload.rating {
            guard appendJSONField("rating", value: ratingWrapper) else { return nil }
        }

        if let statusWrapper = payload.status {
            guard appendJSONField("status", value: statusWrapper) else { return nil }
        }

        if let authors = payload.authors {
            for author in authors {
                guard appendJSONField("authors", value: Optional(author)) else { return nil }
            }
        }

        if let narrators = payload.narrators {
            for narrator in narrators {
                guard appendJSONField("narrators", value: Optional(narrator)) else { return nil }
            }
        }

        if let creators = payload.creators {
            for creator in creators {
                guard appendJSONField("creators", value: creator) else { return nil }
            }
        }

        if let series = payload.series {
            for item in series {
                guard appendJSONField("series", value: item) else { return nil }
            }
        }

        if let collections = payload.collections {
            registerField("collections")
            for collection in collections {
                formEntries.append(("collections", collection))
            }
        }

        if let tags = payload.tags {
            for tag in tags {
                guard appendJSONField("tags", value: Optional(tag)) else { return nil }
            }
        }

        if let textCover {
            registerField("textCover")
            fileEntries.append(("textCover", textCover))
        }

        if let audioCover {
            registerField("audioCover")
            fileEntries.append(("audioCover", audioCover))
        }

        guard !fieldOrder.isEmpty else {
            debugLog("[StorytellerActor] updateBook called without any fields to update.")
            return nil
        }

        for field in fieldOrder {
            appendFormField(&body, boundary: boundary, name: "fields", value: field)
        }

        for entry in formEntries {
            appendFormField(&body, boundary: boundary, name: entry.name, value: entry.value)
        }

        for entry in fileEntries {
            appendFileField(
                &body,
                boundary: boundary,
                name: entry.name,
                file: entry.upload,
            )
        }

        finalizeMultipart(&body, boundary: boundary)

        let headers: [String: String] = [
            "Authorization": authorizationHeaderValue(for: token),
            "Content-Type": "multipart/form-data; boundary=\(boundary)",
            "Accept": "application/json",
        ]

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        do {
            let response = try await httpPut(
                updateURL.absoluteString,
                headers: headers,
                body: body,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "updateBook",
                    context: "book \(payload.uuid)"
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(BookMetadata.self, from: response.data)
            } catch {
                logStorytellerError("updateBook decode", error: error)
                return nil
            }
        } catch {
            logStorytellerError("updateBook", error: error)
            return nil
        }
    }

    /// Deletes a book using `/api/v2/books/{bookId}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (DELETE handler).
    /// TODO: UNTESTED
    func deleteBook(
        _ bookId: String,
        includeAssets option: StorytellerIncludeAssetsOption? = nil,
    ) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let deleteURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)

        var queryParameters: [String: String] = [:]
        if let option {
            queryParameters["includeAssets"] = option.rawValue
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(404)

        do {
            let response = try await httpDelete(
                deleteURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "deleteBook",
                context: "book \(bookId)"
            ) == .success
        } catch {
            logStorytellerError("deleteBook", error: error)
            return false
        }
    }

    /// Merges books via `/api/v2/books/merge`.
    /// Server implementation:  `storyteller/web/src/app/api/v2/books/merge/route.ts`.
    // TODO: UNTESTED
    func mergeBooks(
        update: StorytellerBookMergeUpdate?,
        relations: StorytellerBookRelationsUpdatePayload,
        from bookIds: [String],
    ) async -> BookMetadata? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let mergeURL = baseURL.appendingPathComponent("books/merge")

        struct MergeBody: Encodable {
            let update: StorytellerBookMergeUpdate?
            let relations: StorytellerBookRelationsUpdatePayload
            let from: [String]
        }

        let body = MergeBody(update: update, relations: relations, from: bookIds)

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        do {
            let payload = try encoder.encode(body)
            let response = try await httpPost(
                mergeURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "mergeBooks",
                    context: "merge request \(bookIds.joined(separator: ","))"
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(BookMetadata.self, from: response.data)
            } catch {
                logStorytellerError("mergeBooks decode", error: error)
                return nil
            }
        } catch {
            logStorytellerError("mergeBooks", error: error)
            return nil
        }
    }

    /// Triggers Storyteller's processing pipeline via `/api/v2/books/{bookId}/process`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/process/route.ts`.
    /// TODO: UNTESTED
    func startProcessing(for bookId: String, restart: Bool = false) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let processURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("process")

        var queryParameters: [String: String] = [:]
        if restart {
            queryParameters["restart"] = "true"
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(404)

        do {
            let response = try await httpPost(
                processURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token),
                    "Accept": "application/json",
                ],
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "startProcessing",
                context: "process for \(bookId)"
            ) == .success
        } catch {
            logStorytellerError("startProcessing", error: error)
            return false
        }
    }

    /// Uploads one or more assets for a book using the Tus protocol exposed at `/api/v2/books/upload`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/upload/[[...path]]/route.ts`.
    /// TODO: UNTESTED
    func uploadBookAssets(
        bookUUID: String,
        ebook: StorytellerUploadAsset? = nil,
        audiobook: StorytellerUploadAsset? = nil,
        readaloud: StorytellerUploadAsset? = nil,
        collectionUUID: String? = nil,
    ) async -> Bool {
        let assets = [ebook, audiobook, readaloud].compactMap(\.self)
        guard !assets.isEmpty else {
            debugLog("[StorytellerActor] uploadBookAssets requires at least one asset.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        for (index, asset) in assets.enumerated() {
            let succeeded = await uploadAsset(
                asset,
                bookUUID: bookUUID,
                collectionUUID: index == 0 ? collectionUUID : nil,
                baseURL: baseURL,
                token: token,
            )
            if !succeeded {
                return false
            }
        }
        return true
    }

    private static func resolveAPIBaseURL(from serverURL: URL) -> URL {
        let trimmedPath = serverURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmedPath.hasSuffix("api/v2") {
            return serverURL
        }

        if trimmedPath.hasSuffix("api") {
            return serverURL.appendingPathComponent("v2")
        }

        return
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
    }

    private func authorizationHeaderValue(for token: AccessToken) -> String {
        if token.tokenType.compare("bearer", options: .caseInsensitive) == .orderedSame {
            return "Bearer \(token.accessToken)"
        }
        return "\(token.tokenType) \(token.accessToken)"
    }

    private func fallbackFilename(
        for bookId: String,
        format: StorytellerBookFormat
    ) -> String {
        let fileExtension: String =
            switch format {
                case .ebook, .readaloud:
                    "epub"
                case .audiobook:
                    "m4b"
            }
        return "\(bookId).\(fileExtension)"
    }

    private func defaultFilename(
        for bookId: String,
        format: StorytellerBookFormat,
        response: HTTPURLResponse,
    ) -> String {
        let guessedExtension =
            if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
                let uti = mimeTypeToPreferredExtension(contentType)
            {
                ".\(uti)"
            } else {
                switch format {
                    case .ebook:
                        ".epub"
                    case .audiobook:
                        ".m4b"
                    case .readaloud:
                        ".epub"
                }
            }
        return "\(bookId)\(guessedExtension)"
    }

    private func mimeTypeToPreferredExtension(_ mimeType: String) -> String? {
        if mimeType == "application/epub+zip" { return "epub" }
        if mimeType == "application/zip" { return "zip" }
        if mimeType == "audio/mpeg" { return "mp3" }
        if mimeType == "audio/mp4" { return "m4a" }
        if mimeType == "audio/x-m4a" { return "m4a" }
        return nil
    }

    private func defaultMimeType(for format: StorytellerBookFormat, filename: String) -> String? {
        if let inferred = inferMimeType(from: filename) {
            return inferred
        }
        switch format {
            case .ebook, .readaloud:
                return "application/epub+zip"
            case .audiobook:
                return "application/zip"
        }
    }

    private func inferMimeType(from filename: String) -> String? {
        if filename.lowercased().hasSuffix(".epub") { return "application/epub+zip" }
        if filename.lowercased().hasSuffix(".zip") { return "application/zip" }
        if filename.lowercased().hasSuffix(".mp3") { return "audio/mpeg" }
        if filename.lowercased().hasSuffix(".m4a") { return "audio/m4a" }
        if filename.lowercased().hasSuffix(".m4b") { return "audio/m4b" }
        if filename.lowercased().hasSuffix(".mp4") { return "audio/mp4" }
        return nil
    }

    private func uploadAsset(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        collectionUUID: String?,
        baseURL: URL,
        token: AccessToken,
    ) async -> Bool {
        let uploadBaseURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent("upload")

        var metadata: [String: String] = [
            "bookUuid": bookUUID,
            "filename": asset.filename,
        ]

        if let contentType = asset.contentType {
            metadata["filetype"] = contentType
        } else if let guessedType = defaultMimeType(for: asset.format, filename: asset.filename) {
            metadata["filetype"] = guessedType
        }

        if let relativePath = asset.relativePath {
            metadata["relativePath"] = relativePath
        }

        if let collectionUUID {
            metadata["collection"] = collectionUUID
        }

        let metadataHeader =
            metadata
            .map { key, value in
                let encodedValue = Data(value.utf8).base64EncodedString()
                return "\(key) \(encodedValue)"
            }
            .joined(separator: ",")

        guard !asset.data.isEmpty else {
            debugLog("[StorytellerActor] uploadAsset received empty data for \(asset.filename).")
            return false
        }

        do {
            var createAllowedStatuses = Set(200..<300)
            createAllowedStatuses.insert(401)

            let createResponse = try await httpPost(
                uploadBaseURL.absoluteString,
                headers: [
                    "Tus-Resumable": "1.0.0",
                    "Authorization": authorizationHeaderValue(for: token),
                    "Upload-Length": "\(asset.data.count)",
                    "Upload-Metadata": metadataHeader,
                    "Content-Length": "0",
                ],
                body: Data(),
                session: urlSession,
                allowedStatusCodes: createAllowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    createResponse,
                    methodName: "uploadAsset",
                    context: "create for \(asset.filename)"
                )
            else {
                return false
            }

            guard
                let locationHeader = createResponse.response.value(forHTTPHeaderField: "Location")
            else {
                debugLog("[StorytellerActor] uploadAsset missing Location header.")
                return false
            }

            let uploadURL = resolveUploadLocation(locationHeader, relativeTo: uploadBaseURL)

            var patchAllowedStatuses = Set(200..<300)
            patchAllowedStatuses.insert(401)

            let patchResponse = try await httpPatch(
                uploadURL.absoluteString,
                headers: [
                    "Tus-Resumable": "1.0.0",
                    "Content-Type": "application/offset+octet-stream",
                    "Authorization": authorizationHeaderValue(for: token),
                    "Upload-Offset": "0",
                    "Content-Length": "\(asset.data.count)",
                ],
                body: asset.data,
                session: urlSession,
                allowedStatusCodes: patchAllowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    patchResponse,
                    methodName: "uploadAsset",
                    context: "patch for \(asset.filename)"
                )
            else {
                return false
            }

            let offset = patchResponse.response.value(forHTTPHeaderField: "Upload-Offset")
            if Int(offset ?? "") != asset.data.count {
                debugLog("[StorytellerActor] uploadAsset patch offset mismatch.")
                return false
            }
        } catch {
            logStorytellerError("uploadAsset", error: error)
            return false
        }
        return true
    }

    /// Retrieves available reading statuses from `/api/v2/statuses`.
    /// Server implementation: `storyteller/web/src/app/api/v2/statuses/route.ts`.
    private func fetchStatuses() async -> [BookStatus]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let statusesURL = baseURL.appendingPathComponent("statuses")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                statusesURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchStatuses",
                    context: "statuses"
                )
            else {
                return nil
            }

            let statuses = try decoder.decode([BookStatus].self, from: response.data)
            cachedStatuses = statuses
            return statuses
        } catch {
            logStorytellerError("fetchStatuses", error: error)
            return nil
        }
    }

    /// Returns available statuses for UI display. Uses cached values if available, otherwise fetches from server.
    public func getAvailableStatuses() async -> [BookStatus] {
        if !cachedStatuses.isEmpty {
            return cachedStatuses
        }
        return await fetchStatuses() ?? []
    }

    /// Updates the status for a set of books using `/api/v2/books/status`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/status/route.ts` (PUT handler).
    public func updateStatus(forBooks bookIds: [String], toStatusNamed statusName: String) async -> Bool {
        guard !bookIds.isEmpty else {
            debugLog("[StorytellerActor] updateStatus requires at least one book id.")
            return false
        }

        if cachedStatuses.isEmpty {
            _ = await fetchStatuses()
        }

        guard let status = cachedStatuses.first(where: { $0.name == statusName }) else {
            debugLog("[StorytellerActor] updateStatus error: status '\(statusName)' not found in cached statuses")
            return false
        }

        guard let statusUUID = status.uuid else {
            debugLog("[StorytellerActor] updateStatus error: status '\(statusName)' has no UUID")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let statusURL = baseURL.appendingPathComponent("books/status")

        struct StatusBody: Encodable {
            let books: [String]
            let status: String
        }

        let body = StatusBody(books: bookIds, status: statusUUID)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpPut(
                statusURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "updateStatus",
                context: "status update"
            ) == .success
        } catch {
            logStorytellerError("updateStatus", error: error)
            return false
        }
    }

    /// Retrieves tags visible to the current user from `/api/v2/tags`.
    /// Server implementation: `storyteller/web/src/app/api/v2/tags/route.ts`.
    func fetchTags() async -> [BookTag]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let tagsURL = baseURL.appendingPathComponent("tags")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                tagsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchTags",
                    context: "tags"
                )
            else {
                return nil
            }

            return try decoder.decode([BookTag].self, from: response.data)
        } catch {
            logStorytellerError("fetchTags", error: error)
            return nil
        }
    }

    /// Adds tags to books using `/api/v2/books/tags` (POST).
    /// Server implementation: `storyteller/web/src/app/api/v2/books/tags/route.ts`.
    /// TODO: UNTESTED
    func addTags(_ tags: [String], toBooks bookIds: [String]) async -> Bool {
        guard !tags.isEmpty, !bookIds.isEmpty else {
            debugLog("[StorytellerActor] addTags requires non-empty tags and books.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let tagsURL = baseURL.appendingPathComponent("books/tags")

        struct AddTagsBody: Encodable {
            let tags: [String]
            let books: [String]
        }

        let body = AddTagsBody(tags: tags, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpPost(
                tagsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "addTags",
                context: "tag assignment"
            ) == .success
        } catch {
            logStorytellerError("addTags", error: error)
            return false
        }
    }

    /// Removes tags from books using `/api/v2/books/tags` (DELETE).
    /// Server implementation: `storyteller/web/src/app/api/v2/books/tags/route.ts`.
    /// TODO: UNTESTED
    func removeTags(_ tagUUIDs: [String], fromBooks bookIds: [String]) async -> Bool {
        guard !bookIds.isEmpty else {
            debugLog("[StorytellerActor] removeTags requires at least one book id.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let tagsURL = baseURL.appendingPathComponent("books/tags")

        struct RemoveTagsBody: Encodable {
            let tags: [String]
            let books: [String]
        }

        let body = RemoveTagsBody(tags: tagUUIDs, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpDelete(
                tagsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "removeTags",
                context: "tag removal"
            ) == .success
        } catch {
            logStorytellerError("removeTags", error: error)
            return false
        }
    }

    /// Lists collections visible to the user via `/api/v2/collections`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/route.ts` (GET handler).
    func fetchCollections() async -> [StorytellerCollection]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionsURL = baseURL.appendingPathComponent("collections")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                collectionsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCollections",
                    context: "collections"
                )
            else {
                return nil
            }

            return try decoder.decode([StorytellerCollection].self, from: response.data)
        } catch {
            logStorytellerError("fetchCollections", error: error)
            return nil
        }
    }

    /// Retrieves details for a specific collection via `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (GET handler).
    /// TODO: UNTESTED
    func fetchCollection(uuid: String) async -> StorytellerCollection? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                collectionURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCollection",
                    context: "collection \(uuid)"
                )
            else {
                return nil
            }

            return try decoder.decode(StorytellerCollection.self, from: response.data)
        } catch {
            logStorytellerError("fetchCollection", error: error)
            return nil
        }
    }

    /// Creates a new collection using `/api/v2/collections`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/route.ts` (POST handler).
    /// TODO: UNTESTED
    func createCollection(_ payload: StorytellerCollectionCreatePayload) async
        -> StorytellerCollection?
    {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionsURL = baseURL.appendingPathComponent("collections")

        do {
            let payloadData = try encoder.encode(payload)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpPost(
                collectionsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payloadData,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "createCollection",
                    context: "collection creation"
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(StorytellerCollection.self, from: response.data)
            } catch {
                logStorytellerError("createCollection decode", error: error)
                return nil
            }
        } catch {
            logStorytellerError("createCollection", error: error)
            return nil
        }
    }

    /// Updates collection metadata via `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (PUT handler).
    /// TODO: UNTESTED
    func updateCollection(
        uuid: String,
        payload: StorytellerCollectionUpdatePayload,
    ) async -> StorytellerCollection? {
        guard
            payload.name != nil || payload.description != nil || payload.isPublic != nil
                || payload.users != nil
        else {
            debugLog("[StorytellerActor] updateCollection requires at least one field to update.")
            return nil
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        do {
            let payloadData = try encoder.encode(payload)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(404)

            let response = try await httpPut(
                collectionURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payloadData,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "updateCollection",
                    context: "collection \(uuid)"
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(StorytellerCollection.self, from: response.data)
            } catch {
                logStorytellerError("updateCollection decode", error: error)
                return nil
            }
        } catch {
            logStorytellerError("updateCollection", error: error)
            return nil
        }
    }

    /// Deletes a collection with `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (DELETE handler).
    /// TODO: UNTESTED
    func deleteCollection(uuid: String) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(404)

        do {
            let response = try await httpDelete(
                collectionURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "deleteCollection",
                context: "collection \(uuid)"
            ) == .success
        } catch {
            logStorytellerError("deleteCollection", error: error)
            return false
        }
    }

    /// Adds book memberships to collections via `/api/v2/collections/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/books/route.ts` (POST handler).
    /// TODO: UNTESTED
    func addBooks(_ bookIds: [String], toCollections collectionIds: [String]) async -> Bool {
        guard !bookIds.isEmpty, !collectionIds.isEmpty else {
            debugLog("[StorytellerActor] addBooks requires non-empty books and collections.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let membershipURL = baseURL.appendingPathComponent("collections/books")

        struct MembershipBody: Encodable {
            let collections: [String]
            let books: [String]
        }

        let body = MembershipBody(collections: collectionIds, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpPost(
                membershipURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "addBooks",
                context: "membership add"
            ) == .success
        } catch {
            logStorytellerError("addBooks", error: error)
            return false
        }
    }

    /// Removes book memberships from collections via `/api/v2/collections/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/books/route.ts` (DELETE handler).
    /// TODO: UNTESTED
    func removeBooks(_ bookIds: [String], fromCollections collectionIds: [String]) async -> Bool {
        guard !bookIds.isEmpty, !collectionIds.isEmpty else {
            debugLog("[StorytellerActor] removeBooks requires non-empty books and collections.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let membershipURL = baseURL.appendingPathComponent("collections/books")

        struct MembershipBody: Encodable {
            let collections: [String]
            let books: [String]
        }

        let body = MembershipBody(collections: collectionIds, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpDelete(
                membershipURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            return evaluateResponse(
                response,
                methodName: "removeBooks",
                context: "membership removal"
            ) == .success
        } catch {
            logStorytellerError("removeBooks", error: error)
            return false
        }
    }

    /// Logs out of the remote Storyteller instance and clears cached auth state.
    /// Server implementation: `storyteller/web/src/app/api/v2/logout/route.ts`.
    public func logout() async -> Bool {
        guard let token = accessToken else {
            libraryMetadata.removeAll()
            return true
        }
        guard let apiBaseURL = apiBaseURL else {
            return false
        }

        let logoutURL = apiBaseURL.appendingPathComponent("logout")

        var succeeded = true
        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)

            let response = try await httpPost(
                logoutURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses
            )

            let status = evaluateResponse(response, methodName: "logout", context: "session")
            switch status {
                case .success, .unauthorized:
                    break
                default:
                    succeeded = false
            }
        } catch {
            logStorytellerError("logout", error: error)
            succeeded = false
        }

        accessToken = nil
        username = nil
        password = nil
        self.apiBaseURL = nil
        libraryMetadata.removeAll()
        await updateConnectionStatus(.disconnected)
        monitoringTask?.cancel()
        monitoringTask = nil
        return succeeded
    }

    private enum StorytellerResponseStatus: Equatable {
        case success
        case notModified
        case unauthorized
        case notFound
        case unexpected(Int)
    }

    private func evaluateResponse(
        _ response: HTTPResponse,
        methodName: String,
        context: String
    ) -> StorytellerResponseStatus {
        let statusCode = response.statusCode

        if (200..<300).contains(statusCode) {
            return .success
        }

        switch statusCode {
            case 304:
                debugLog("[StorytellerActor] \(methodName) \(context) not modified.")
                return .notModified
            case 401, 403:
                debugLog(
                    "[StorytellerActor] \(methodName) \(context) unauthorized (\(statusCode))."
                )
                accessToken = nil
                Task { await self.updateConnectionStatus(.error("Unauthorized")) }
                return .unauthorized
            case 404:
                debugLog("[StorytellerActor] \(methodName) \(context) not found.")
                return .notFound
            default:
                if let body = String(data: response.data, encoding: .utf8), !body.isEmpty {
                    debugLog(
                        "[StorytellerActor] \(methodName) \(context) unexpected status \(statusCode): \(body)"
                    )
                } else {
                    debugLog(
                        "[StorytellerActor] \(methodName) \(context) unexpected status \(statusCode)."
                    )
                }
                return .unexpected(statusCode)
        }
    }

    private func resolveUploadLocation(_ locationHeader: String, relativeTo baseURL: URL) -> URL {
        if let explicit = URL(string: locationHeader), explicit.host != nil {
            return explicit
        }

        if locationHeader.hasPrefix("/") {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = locationHeader
            components?.query = nil
            components?.fragment = nil
            if let url = components?.url { return url }
        }

        return baseURL.appendingPathComponent(locationHeader)
    }

    private func appendFormField(
        _ body: inout Data,
        boundary: String,
        name: String,
        value: String,
    ) {
        guard let headerData = "--\(boundary)\r\n".data(using: .utf8) else { return }
        body.append(headerData)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8) ?? Data())
        body.append("\r\n".data(using: .utf8)!)
    }

    private func appendFileField(
        _ body: inout Data,
        boundary: String,
        name: String,
        file: StorytellerCoverUpload,
    ) {
        guard let headerData = "--\(boundary)\r\n".data(using: .utf8) else { return }
        body.append(headerData)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n"
                .data(using: .utf8)!,
        )
        if let contentType = file.contentType {
            body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        } else {
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        }
        body.append(file.data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func finalizeMultipart(_ body: inout Data, boundary: String) {
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    }

    private nonisolated func jsonFragment(from value: (some Encodable)?) -> String? {
        if let value {
            do {
                let data = try encoder.encode(value)
                guard let string = String(data: data, encoding: .utf8) else {
                    debugLog("[StorytellerActor] Failed to encode JSON fragment: invalid UTF-8.")
                    return nil
                }
                return string
            } catch {
                logStorytellerError("jsonFragment encode", error: error)
                return nil
            }
        }
        return "null"
    }

    private func encodeLocatorToDict(_ locator: BookLocator) -> [String: Any] {
        var dict: [String: Any] = [
            "href": locator.href,
            "type": locator.type,
        ]

        if let title = locator.title {
            dict["title"] = title
        }

        if let locations = locator.locations {
            var locationsDict: [String: Any] = [:]

            if let progression = locations.progression {
                locationsDict["progression"] = progression
            }
            if let totalProgression = locations.totalProgression {
                locationsDict["totalProgression"] = totalProgression
            }
            if let position = locations.position {
                locationsDict["position"] = position
            }
            if let partialCfi = locations.partialCfi {
                locationsDict["partialCfi"] = partialCfi
            }
            if let cssSelector = locations.cssSelector {
                locationsDict["cssSelector"] = cssSelector
            }
            if let fragments = locations.fragments {
                locationsDict["fragments"] = fragments
            }

            if !locationsDict.isEmpty {
                dict["locations"] = locationsDict
            }
        }

        if let text = locator.text {
            var textDict: [String: Any] = [:]
            if let before = text.before {
                textDict["before"] = before
            }
            if let after = text.after {
                textDict["after"] = after
            }
            if let highlight = text.highlight {
                textDict["highlight"] = highlight
            }

            if !textDict.isEmpty {
                dict["text"] = textDict
            }
        }

        debugLog("[StorytellerActor] Encoded locator to dictionary")
        return dict
    }

    // MARK: - PSA REST Methods (Pure REST, no queue logic)

    public func sendProgressToServer(
        bookId: String,
        locator: BookLocator,
        timestamp: Double
    ) async -> HTTPResult {
        debugLog(
            "[StorytellerActor] sendProgressToServer: bookId=\(bookId), timestamp=\(timestamp)"
        )

        guard let baseURL = apiBaseURL else {
            debugLog("[StorytellerActor] sendProgressToServer: no API base URL")
            return .noConnection
        }

        guard let token = accessToken?.accessToken else {
            debugLog("[StorytellerActor] sendProgressToServer: no access token")
            return .noConnection
        }

        let url = baseURL.appendingPathComponent("books/\(bookId)/positions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "locator": encodeLocatorToDict(locator),
            "timestamp": Int64(timestamp),
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("[StorytellerActor] sendProgressToServer: invalid response type")
                return .failure
            }

            debugLog("[StorytellerActor] sendProgressToServer: status=\(httpResponse.statusCode)")

            switch httpResponse.statusCode {
                case 204:
                    return .success
                case 409, 404:
                    return .failure
                default:
                    return .failure
            }
        } catch {
            debugLog("[StorytellerActor] sendProgressToServer: request failed - \(error)")
            return .noConnection
        }
    }

    public func fetchBookPosition(bookId: String) async -> BookLocator? {
        debugLog("[StorytellerActor] fetchBookPosition: bookId=\(bookId)")

        guard let metadata = await fetchBookDetails(for: bookId) else {
            debugLog("[StorytellerActor] fetchBookPosition: failed to fetch metadata")
            return nil
        }

        guard let position = metadata.position, let locator = position.locator else {
            debugLog("[StorytellerActor] fetchBookPosition: no position in metadata")
            return nil
        }

        debugLog("[StorytellerActor] fetchBookPosition: found locator with href=\(locator.href)")
        return locator
    }

    public func fetchBookProgress(bookId: String, log: Bool = true) async -> BookReadingPosition? {
        if log {
            debugLog("[StorytellerActor] fetchBookProgress: bookId=\(bookId)")
        }

        guard let metadata = await fetchBookDetails(for: bookId) else {
            if log {
                debugLog("[StorytellerActor] fetchBookProgress: failed to fetch metadata")
            }
            return nil
        }

        if log {
            debugLog(
                "[StorytellerActor] fetchBookProgress: returning position with timestamp=\(metadata.position?.timestamp ?? 0)"
            )
        }
        return metadata.position
    }

    // TODO: Remaining API wrappers
    // - `/api/v2/books/events` (storyteller/web/src/app/api/v2/books/events/route.ts) – real-time catalogue updates.
    // - `/api/v2/books` POST/DELETE (storyteller/web/src/app/api/v2/books/route.ts) – server-side ingest utilities.
    // - `/api/v2/books/[bookId]/cache` (storyteller/web/src/app/api/v2/books/[bookId]/cache/route.ts) – purge cached assets.
    // - `/api/v2/books/[bookId]/process` DELETE (storyteller/web/src/app/api/v2/books/[bookId]/process/route.ts) – cancel processing jobs.
    // - `/api/v2/series` & `/api/v2/series/books` (storyteller/web/src/app/api/v2/series/**/*.ts) – manage series metadata.
    // - `/api/v2/settings` & `/api/v2/settings/maxUploadChunkSize` (storyteller/web/src/app/api/v2/settings/**/*.ts) – admin settings.
    // - `/api/v2/creators` (storyteller/web/src/app/api/v2/creators/route.ts) – creator directory.
    // - `/api/v2/users` and `/api/v2/users/{userId}` (storyteller/web/src/app/api/v2/users/**/*.ts) – user administration.
    // - `/api/v2/invites` endpoints (storyteller/web/src/app/api/v2/invites/**/*.ts) – invite management.
    // - `/api/v2/reports` (storyteller/web/src/app/api/v2/reports/**/*.ts) – processing reports and transcripts.
    // - `/api/v2/validate` (storyteller/web/src/app/api/v2/validate/route.ts) – session validation helper.
}

private enum StorytellerDownloadError: Error, Sendable {
    case missingTaskState
    case fileMoveFailed(underlying: Error)
}

private final class StorytellerDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    URLSessionTaskDelegate
{
    struct TaskState: Sendable {
        var continuation: AsyncThrowingStream<StorytellerDownloadEvent, Error>.Continuation
        let fallbackFilename: String
        let bookId: String
        let format: StorytellerBookFormat
        let failureHandler: @Sendable (StorytellerDownloadFailure) -> Void
        var filename: String?
        var expectedBytes: Int64?
        var contentType: String?
        var etag: String?
        var lastModified: String?
        var lastProgressTime: CFAbsoluteTime = 0
    }

    private let stateQueue = DispatchQueue(
        label: "com.kyonifer.silveran.storyteller.download-state"
    )
    private var states: [Int: TaskState] = [:]

    func register(task: URLSessionDownloadTask, state: TaskState) {
        stateQueue.sync {
            self.states[task.taskIdentifier] = state
        }
    }

    private func mutateState<Result>(
        for task: URLSessionTask,
        _ mutation: (inout TaskState) -> Result
    ) -> (TaskState, Result)? {
        var updatedState: TaskState?
        var mutationResult: Result?
        stateQueue.sync {
            guard var state = states[task.taskIdentifier] else { return }
            let result = mutation(&state)
            states[task.taskIdentifier] = state
            updatedState = state
            mutationResult = result
        }
        if let updatedState, let mutationResult {
            return (updatedState, mutationResult)
        }
        return nil
    }

    private func removeState(for task: URLSessionTask) -> TaskState? {
        var removed: TaskState?
        stateQueue.sync {
            removed = states.removeValue(forKey: task.taskIdentifier)
        }
        return removed
    }

    @objc(urlSession:downloadTask:didReceiveResponse:completionHandler:)
    private func handleDownloadResponse(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            if let state = removeState(for: downloadTask) {
                state.failureHandler(.nonHTTPResponse)
                state.continuation.finish(throwing: StorytellerDownloadFailure.nonHTTPResponse)
            }
            completionHandler(.cancel)
            return
        }

        let statusCode = httpResponse.statusCode
        guard (200..<300).contains(statusCode) else {
            let failure: StorytellerDownloadFailure
            switch statusCode {
                case 401, 403:
                    failure = .unauthorized
                case 404:
                    failure = .notFound
                default:
                    failure = .unexpectedStatus(statusCode)
            }
            if let state = removeState(for: downloadTask) {
                state.failureHandler(failure)
                state.continuation.finish(throwing: failure)
            }
            completionHandler(.cancel)
            return
        }

        let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        let resolvedFilename =
            mutateState(for: downloadTask) { state -> StorytellerDownloadEvent in
                let filename =
                    parseFilename(fromContentDisposition: contentDisposition)
                    ?? state.fallbackFilename
                let contentLengthString = httpResponse.value(forHTTPHeaderField: "Content-Length")
                let expectedLength = contentLengthString.flatMap { Int64($0) }
                state.filename = filename
                state.expectedBytes = expectedLength
                state.contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
                state.etag = httpResponse.value(forHTTPHeaderField: "Etag")
                state.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
                return .response(
                    filename: filename,
                    expectedBytes: expectedLength,
                    contentType: state.contentType,
                    etag: state.etag,
                    lastModified: state.lastModified
                )
            }

        if let (state, event) = resolvedFilename {
            state.continuation.yield(event)
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let updateResult = mutateState(for: downloadTask) { state -> (Int64?, String, Bool) in
            if state.expectedBytes == nil, totalBytesExpectedToWrite > 0 {
                state.expectedBytes = totalBytesExpectedToWrite
            }
            let shouldEmit = now - state.lastProgressTime >= 0.1
            if shouldEmit {
                state.lastProgressTime = now
            }
            return (state.expectedBytes, state.bookId, shouldEmit)
        }

        guard let (state, (expectedBytes, _, shouldEmit)) = updateResult, shouldEmit else { return }
        state.continuation.yield(
            .progress(
                receivedBytes: totalBytesWritten,
                expectedBytes: expectedBytes
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let persistentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: persistentURL.path) {
                try fm.removeItem(at: persistentURL)
            }
            try fm.moveItem(at: location, to: persistentURL)
        } catch {
            if let state = removeState(for: downloadTask) {
                state.continuation.finish(
                    throwing: StorytellerDownloadError.fileMoveFailed(underlying: error)
                )
            }
            return
        }

        if let state = removeState(for: downloadTask) {
            state.continuation.yield(.finished(temporaryURL: persistentURL))
            state.continuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        if let urlError = error as? URLError {
            switch urlError.code {
                case .notConnectedToInternet,
                    .networkConnectionLost,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .timedOut,
                    .dnsLookupFailed:
                    Task {
                        await StorytellerActor.shared.setLastNetworkOpSucceeded(false)
                    }
                default:
                    break
            }
        }

        if let state = removeState(for: task) {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                state.continuation.finish()
            } else {
                state.continuation.finish(throwing: error)
            }
        }
    }

    @objc(urlSession:task:didReceiveResponse:completionHandler:)
    func handleTaskResponse(
        _ session: URLSession,
        task: URLSessionTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let downloadTask = task as? URLSessionDownloadTask {
            handleDownloadResponse(
                session,
                downloadTask: downloadTask,
                response: response,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.allow)
        }
    }
}

extension StorytellerDownloadDelegate: @unchecked Sendable {}

func logStorytellerError(_ message: String, error: Error) {
    debugLog("[StorytellerActor] \(message): \(error)")

    if let urlError = error as? URLError {
        switch urlError.code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .cannotFindHost,
                .cannotConnectToHost,
                .timedOut,
                .dnsLookupFailed:
                Task {
                    await StorytellerActor.shared.setLastNetworkOpSucceeded(false)
                }
            default:
                break
        }
    }
}

func logDetailedDecodingError(_ error: DecodingError, data: Data) {
    switch error {
        case .typeMismatch(let type, let context):
            debugLog("[StorytellerActor] Type mismatch for type \(type)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        case .valueNotFound(let type, let context):
            debugLog("[StorytellerActor] Value not found for type \(type)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        case .keyNotFound(let key, let context):
            debugLog("[StorytellerActor] Key not found: \(key.stringValue)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
        case .dataCorrupted(let context):
            debugLog("[StorytellerActor] Data corrupted")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        @unknown default:
            debugLog("[StorytellerActor] Unknown decoding error: \(error)")
    }
}

func printJSONSnippet(data: Data, codingPath: [CodingKey]) {
    guard let jsonData = try? JSONSerialization.jsonObject(with: data)
    else {
        debugLog("[StorytellerActor] Could not parse JSON for snippet")
        return
    }

    var current: Any = jsonData
    var pathSoFar: [String] = []

    for key in codingPath {
        pathSoFar.append(key.stringValue)
        if let dict = current as? [String: Any], let next = dict[key.stringValue] {
            current = next
        } else if let array = current as? [Any], let index = key.intValue, index < array.count {
            current = array[index]
        } else {
            debugLog(
                "[StorytellerActor] Could not navigate to path: \(pathSoFar.joined(separator: " -> "))"
            )
            return
        }
    }

    if let snippetData = try? JSONSerialization.data(
        withJSONObject: current,
        options: [.prettyPrinted, .sortedKeys]
    ),
        let snippetString = String(data: snippetData, encoding: .utf8)
    {
        debugLog(
            "[StorytellerActor] JSON at error location (\(pathSoFar.joined(separator: " -> "))):"
        )
        let lines = snippetString.split(separator: "\n")
        for (index, line) in lines.prefix(20).enumerated() {
            debugLog("[StorytellerActor]   \(line)")
            if index == 19 && lines.count > 20 {
                debugLog("[StorytellerActor]   ... (\(lines.count - 20) more lines)")
            }
        }
    }
}

func parseFilename(fromContentDisposition contentDisposition: String?) -> String? {
    guard let contentDisposition else { return nil }
    let components = contentDisposition.split(separator: ";")
    var foundFile: String? = nil
    for component in components {
        let trimmed = component.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("filename*=") {
            // RFC 5987 encoded
            let value = trimmed.dropFirst("filename*=".count)
            if let encoded = value.split(separator: "''", maxSplits: 1).last,
                let decoded = encoded.removingPercentEncoding
            {
                return decoded
            }
        }
        if trimmed.lowercased().hasPrefix("filename=") {
            let value = trimmed.dropFirst("filename=".count)
            foundFile = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
    return foundFile ?? nil
}
