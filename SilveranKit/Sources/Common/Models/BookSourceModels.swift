import Foundation

public typealias BookSourceID = String

public enum BookSourceKind: String, Codable, Sendable, Hashable {
    case storyteller
    case localFolder
}

public struct SourceConnectionInfo: Sendable, Identifiable, Equatable {
    public let id: BookSourceID
    public let name: String
    public let kind: BookSourceKind
    public let status: ConnectionStatus

    public init(id: BookSourceID, name: String, kind: BookSourceKind, status: ConnectionStatus) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
    }
}

public struct BookSourceCapabilities: Codable, Sendable, Hashable {
    public var canEditMetadata: Bool
    public var canManageMedia: Bool
    public var canProcessReadaloud: Bool
    public var canUploadBooks: Bool
    public var canSyncProgress: Bool

    public init(
        canEditMetadata: Bool,
        canManageMedia: Bool,
        canProcessReadaloud: Bool,
        canUploadBooks: Bool,
        canSyncProgress: Bool,
    ) {
        self.canEditMetadata = canEditMetadata
        self.canManageMedia = canManageMedia
        self.canProcessReadaloud = canProcessReadaloud
        self.canUploadBooks = canUploadBooks
        self.canSyncProgress = canSyncProgress
    }
}

public struct BookSourceRecord: Codable, Identifiable, Sendable, Hashable {
    public static let sourceIDFilename = ".silveran_source_id"

    public var id: BookSourceID
    public var name: String
    public var kind: BookSourceKind
    public var capabilities: BookSourceCapabilities
    public var createdAt: String?
    public var updatedAt: String?
    public var storagePath: String?
    public var storageBookmarkData: Data?

    public init(
        id: BookSourceID,
        name: String,
        kind: BookSourceKind,
        capabilities: BookSourceCapabilities,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        storagePath: String? = nil,
        storageBookmarkData: Data? = nil,
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.storagePath = storagePath
        self.storageBookmarkData = storageBookmarkData
    }
}

public struct BookSourceConfiguration: Sendable, Hashable {
    public var kind: BookSourceKind
    public var name: String
    public var serverURL: String?
    public var username: String?
    public var password: String?
    public var storagePath: String?
    public var storageBookmarkData: Data?

    public init(
        kind: BookSourceKind,
        name: String,
        serverURL: String? = nil,
        username: String? = nil,
        password: String? = nil,
        storagePath: String? = nil,
        storageBookmarkData: Data? = nil,
    ) {
        self.kind = kind
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.storagePath = storagePath
        self.storageBookmarkData = storageBookmarkData
    }
}

public enum LocalMediaLocationKind: String, Sendable, Codable, Hashable {
    case cached
    case source
}

public struct ResolvedLocalMedia: Sendable, Hashable {
    public let bookID: String
    public let sourceID: BookSourceID
    public let category: LocalMediaCategory
    public let url: URL
    public let kind: LocalMediaLocationKind

    public init(
        bookID: String,
        sourceID: BookSourceID,
        category: LocalMediaCategory,
        url: URL,
        kind: LocalMediaLocationKind,
    ) {
        self.bookID = bookID
        self.sourceID = sourceID
        self.category = category
        self.url = url
        self.kind = kind
    }
}

public struct PreparedEbookMedia: Sendable, Hashable {
    public let bookID: String
    public let sourceID: BookSourceID
    public let category: LocalMediaCategory
    public let originalURL: URL
    public let readerURL: URL
    public let locationKind: LocalMediaLocationKind
    public let isExtracted: Bool

    public init(
        bookID: String,
        sourceID: BookSourceID,
        category: LocalMediaCategory,
        originalURL: URL,
        readerURL: URL,
        locationKind: LocalMediaLocationKind,
        isExtracted: Bool,
    ) {
        self.bookID = bookID
        self.sourceID = sourceID
        self.category = category
        self.originalURL = originalURL
        self.readerURL = readerURL
        self.locationKind = locationKind
        self.isExtracted = isExtracted
    }
}

public enum LocalMediaAvailability: Sendable, Hashable {
    case available(ResolvedLocalMedia)
    case missing
    case offline
}

public enum LibrarySnapshotPolicy: Sendable, Hashable {
    case cachedOnly
    case cachedThenRefresh
    case refresh
}

public enum BookRefreshPolicy: Sendable, Hashable {
    case cachedOnly
    case refresh
    case forceRefresh
}

public enum BookRefreshSource: Sendable, Hashable {
    case cache
    case source
}

public enum CoverLoadPolicy: Sendable, Hashable {
    case cachedThenFetch
    case forceRefresh
}

public enum CoverLoadResponse: Sendable {
    case cached(Data)
    case fetched(BookCover)
    case missing
    case skippedOffline
}

public struct BookRefreshResult: Sendable, Hashable {
    public let book: BookMetadata?
    public let source: BookRefreshSource
    public let error: String?

    public init(book: BookMetadata?, source: BookRefreshSource, error: String? = nil) {
        self.book = book
        self.source = source
        self.error = error
    }
}

public struct BookServiceLibrarySnapshot: Sendable {
    public let books: [BookMetadata]
    public let mediaPaths: [String: MediaPaths]
    public let cachedMediaPaths: [String: MediaPaths]
    public let sources: [BookSourceRecord]

    public init(
        books: [BookMetadata],
        mediaPaths: [String: MediaPaths],
        cachedMediaPaths: [String: MediaPaths],
        sources: [BookSourceRecord],
    ) {
        self.books = books
        self.mediaPaths = mediaPaths
        self.cachedMediaPaths = cachedMediaPaths
        self.sources = sources
    }
}

extension BookSourceKind {
    public var displayName: String {
        switch self {
            case .storyteller:
                return "Storyteller"
            case .localFolder:
                return "Folder Source"
        }
    }

    public var defaultName: String {
        switch self {
            case .storyteller:
                return "My Storyteller Server"
            case .localFolder:
                return "Internal Storage"
        }
    }
}

public protocol BookSourceActor: Actor {
    var sourceRecord: BookSourceRecord { get async }
    var connectionStatus: ConnectionStatus { get async }

    func fetchLibraryInformation() async -> [BookMetadata]?

    func fetchCoverImage(
        for bookId: String,
        audio: Bool,
        width: Int?,
        height: Int?,
        version: String?,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
    ) async -> BookCover?

    func sendProgressToServer(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async -> HTTPResult

    func fetchBookPosition(bookId: String) async -> BookReadingPosition?
}

extension BookSourceCapabilities {
    public static var storyteller: BookSourceCapabilities {
        BookSourceCapabilities(
            canEditMetadata: true,
            canManageMedia: true,
            canProcessReadaloud: true,
            canUploadBooks: true,
            canSyncProgress: true,
        )
    }

    public static var localFolder: BookSourceCapabilities {
        BookSourceCapabilities(
            canEditMetadata: false,
            canManageMedia: true,
            canProcessReadaloud: false,
            canUploadBooks: true,
            canSyncProgress: true,
        )
    }
}
