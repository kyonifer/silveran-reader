import Foundation

public enum WatchProtocolV2 {
    public static let version = 2
    public static let versionKey = "version"
    public static let typeKey = "type"
    public static let payloadKey = "payload"
}

public enum WatchProtocolError: Error, Equatable {
    case missingVersion
    case unsupportedVersion(Int)
    case missingMessageType
    case unknownMessageType(String)
    case missingPayload
}

public struct WatchProtocolContext: Codable, Hashable, Sendable {
    public let sourceIDs: [BookSourceID]

    public init(sourceIDs: [BookSourceID]) {
        self.sourceIDs = sourceIDs
    }
}

public struct WatchFailure: Codable, Hashable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct WatchProgressPayload: Codable, Hashable, Sendable {
    public let bookID: BookID
    public let locator: BookLocator
    public let timestamp: Double

    public init(bookID: BookID, locator: BookLocator, timestamp: Double) {
        self.bookID = bookID
        self.locator = locator
        self.timestamp = timestamp
    }
}

public struct WatchDeleteBookPayload: Codable, Hashable, Sendable {
    public let bookID: BookID
    public let category: LocalMediaCategory

    public init(bookID: BookID, category: LocalMediaCategory) {
        self.bookID = bookID
        self.category = category
    }
}

public struct WatchTransferReference: Codable, Hashable, Sendable {
    public let transferID: UUID

    public init(transferID: UUID) {
        self.transferID = transferID
    }
}

public struct WatchChunkTransferPayload: Codable, Hashable, Sendable {
    public let transferID: UUID
    public let bookID: BookID
    public let category: LocalMediaCategory
    public let chunkIndex: Int
    public let totalChunks: Int
    public let totalFileSize: Int64
    public let fileExtension: String
    public let title: String
    public let authors: [String]
    public let bookMetadata: BookMetadata

    public init(
        transferID: UUID,
        bookID: BookID,
        category: LocalMediaCategory,
        chunkIndex: Int,
        totalChunks: Int,
        totalFileSize: Int64,
        fileExtension: String,
        title: String,
        authors: [String],
        bookMetadata: BookMetadata,
    ) {
        self.transferID = transferID
        self.bookID = bookID
        self.category = category
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.totalFileSize = totalFileSize
        self.fileExtension = fileExtension
        self.title = title
        self.authors = authors
        self.bookMetadata = bookMetadata
    }
}

public struct WatchCredentialSourceInfo: Codable, Hashable, Sendable, Identifiable {
    public let sourceID: BookSourceID
    public let name: String
    public let url: String
    public let username: String

    public var id: BookSourceID { sourceID }

    public init(sourceID: BookSourceID, name: String, url: String, username: String) {
        self.sourceID = sourceID
        self.name = name
        self.url = url
        self.username = username
    }
}

public struct WatchSourceCatalog: Codable, Hashable, Sendable {
    public let sources: [WatchCredentialSourceInfo]

    public init(sources: [WatchCredentialSourceInfo]) {
        self.sources = sources
    }
}

public struct WatchCredentialRequest: Codable, Hashable, Sendable {
    public let sourceID: BookSourceID

    public init(sourceID: BookSourceID) {
        self.sourceID = sourceID
    }
}

public struct WatchCredentialReply: Codable, Hashable, Sendable {
    public let sourceID: BookSourceID
    public let name: String
    public let url: String
    public let username: String
    public let password: String

    public init(
        sourceID: BookSourceID,
        name: String,
        url: String,
        username: String,
        password: String,
    ) {
        self.sourceID = sourceID
        self.name = name
        self.url = url
        self.username = username
        self.password = password
    }
}

public struct WatchBookInfo: Codable, Hashable, Sendable, Identifiable {
    public struct ID: Codable, Hashable, Sendable {
        public let bookID: BookID
        public let category: LocalMediaCategory

        public init(bookID: BookID, category: LocalMediaCategory) {
            self.bookID = bookID
            self.category = category
        }
    }

    public let id: ID
    public let title: String
    public let authorNames: [String]
    public let sizeBytes: Int64

    public var bookID: BookID { id.bookID }
    public var category: LocalMediaCategory { id.category }
    public var authorDisplay: String { authorNames.joined(separator: ", ") }

    public init(
        bookID: BookID,
        title: String,
        authorNames: [String],
        category: LocalMediaCategory,
        sizeBytes: Int64,
    ) {
        id = ID(bookID: bookID, category: category)
        self.title = title
        self.authorNames = authorNames
        self.sizeBytes = sizeBytes
    }
}

public struct WatchLibrary: Codable, Hashable, Sendable {
    public let books: [WatchBookInfo]

    public init(books: [WatchBookInfo]) {
        self.books = books
    }
}

public struct WatchLibraryMetadataResponse: Codable, Hashable, Sendable {
    public let books: [BookMetadata]

    public init(books: [BookMetadata]) {
        self.books = books
    }
}

public enum WatchProtocolMessage: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case context
        case ping
        case pong
        case acknowledgement
        case failure
        case progress
        case deleteBook
        case cancelTransfer
        case transferComplete
        case chunkTransfer
        case sourceCatalogRequest
        case sourceCatalog
        case credentialRequest
        case credentialReply
        case watchLibraryRequest
        case watchLibrary
        case libraryMetadataRequest
        case libraryMetadataResponse
        case playbackStateRequest
        case playbackState
        case noPlaybackState
        case playbackCommand
    }

    case context(WatchProtocolContext)
    case ping
    case pong
    case acknowledgement
    case failure(WatchFailure)
    case progress(WatchProgressPayload)
    case deleteBook(WatchDeleteBookPayload)
    case cancelTransfer(WatchTransferReference)
    case transferComplete(WatchTransferReference)
    case chunkTransfer(WatchChunkTransferPayload)
    case sourceCatalogRequest
    case sourceCatalog(WatchSourceCatalog)
    case credentialRequest(WatchCredentialRequest)
    case credentialReply(WatchCredentialReply)
    case watchLibraryRequest
    case watchLibrary(WatchLibrary)
    case libraryMetadataRequest
    case libraryMetadataResponse(WatchLibraryMetadataResponse)
    case playbackStateRequest
    case playbackState(RemotePlaybackState)
    case noPlaybackState
    case playbackCommand(RemotePlaybackCommand)

    public var kind: Kind {
        switch self {
            case .context: .context
            case .ping: .ping
            case .pong: .pong
            case .acknowledgement: .acknowledgement
            case .failure: .failure
            case .progress: .progress
            case .deleteBook: .deleteBook
            case .cancelTransfer: .cancelTransfer
            case .transferComplete: .transferComplete
            case .chunkTransfer: .chunkTransfer
            case .sourceCatalogRequest: .sourceCatalogRequest
            case .sourceCatalog: .sourceCatalog
            case .credentialRequest: .credentialRequest
            case .credentialReply: .credentialReply
            case .watchLibraryRequest: .watchLibraryRequest
            case .watchLibrary: .watchLibrary
            case .libraryMetadataRequest: .libraryMetadataRequest
            case .libraryMetadataResponse: .libraryMetadataResponse
            case .playbackStateRequest: .playbackStateRequest
            case .playbackState: .playbackState
            case .noPlaybackState: .noPlaybackState
            case .playbackCommand: .playbackCommand
        }
    }

    public func encode(using encoder: JSONEncoder = JSONEncoder()) throws -> [String: Any] {
        let payload: Data
        switch self {
            case .context(let value):
                payload = try encoder.encode(value)
            case .ping, .pong, .acknowledgement, .sourceCatalogRequest,
                .watchLibraryRequest, .libraryMetadataRequest, .playbackStateRequest,
                .noPlaybackState:
                payload = try encoder.encode(EmptyPayload())
            case .failure(let value):
                payload = try encoder.encode(value)
            case .progress(let value):
                payload = try encoder.encode(value)
            case .deleteBook(let value):
                payload = try encoder.encode(value)
            case .cancelTransfer(let value), .transferComplete(let value):
                payload = try encoder.encode(value)
            case .chunkTransfer(let value):
                payload = try encoder.encode(value)
            case .sourceCatalog(let value):
                payload = try encoder.encode(value)
            case .credentialRequest(let value):
                payload = try encoder.encode(value)
            case .credentialReply(let value):
                payload = try encoder.encode(value)
            case .watchLibrary(let value):
                payload = try encoder.encode(value)
            case .libraryMetadataResponse(let value):
                payload = try encoder.encode(value)
            case .playbackState(let value):
                payload = try encoder.encode(value)
            case .playbackCommand(let value):
                payload = try encoder.encode(value)
        }

        return [
            WatchProtocolV2.versionKey: WatchProtocolV2.version,
            WatchProtocolV2.typeKey: kind.rawValue,
            WatchProtocolV2.payloadKey: payload,
        ]
    }

    public static func decode(
        from envelope: [String: Any],
        using decoder: JSONDecoder = JSONDecoder(),
    ) throws -> WatchProtocolMessage {
        guard let version = envelope[WatchProtocolV2.versionKey] as? Int else {
            throw WatchProtocolError.missingVersion
        }
        guard version == WatchProtocolV2.version else {
            throw WatchProtocolError.unsupportedVersion(version)
        }
        guard let rawKind = envelope[WatchProtocolV2.typeKey] as? String else {
            throw WatchProtocolError.missingMessageType
        }
        guard let kind = Kind(rawValue: rawKind) else {
            throw WatchProtocolError.unknownMessageType(rawKind)
        }
        guard let payload = envelope[WatchProtocolV2.payloadKey] as? Data else {
            throw WatchProtocolError.missingPayload
        }

        switch kind {
            case .context:
                return .context(try decoder.decode(WatchProtocolContext.self, from: payload))
            case .ping:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .ping
            case .pong:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .pong
            case .acknowledgement:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .acknowledgement
            case .failure:
                return .failure(try decoder.decode(WatchFailure.self, from: payload))
            case .progress:
                return .progress(try decoder.decode(WatchProgressPayload.self, from: payload))
            case .deleteBook:
                return .deleteBook(
                    try decoder.decode(WatchDeleteBookPayload.self, from: payload)
                )
            case .cancelTransfer:
                return .cancelTransfer(
                    try decoder.decode(WatchTransferReference.self, from: payload)
                )
            case .transferComplete:
                return .transferComplete(
                    try decoder.decode(WatchTransferReference.self, from: payload)
                )
            case .chunkTransfer:
                return .chunkTransfer(
                    try decoder.decode(WatchChunkTransferPayload.self, from: payload)
                )
            case .sourceCatalogRequest:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .sourceCatalogRequest
            case .sourceCatalog:
                return .sourceCatalog(try decoder.decode(WatchSourceCatalog.self, from: payload))
            case .credentialRequest:
                return .credentialRequest(
                    try decoder.decode(WatchCredentialRequest.self, from: payload)
                )
            case .credentialReply:
                return .credentialReply(
                    try decoder.decode(WatchCredentialReply.self, from: payload)
                )
            case .watchLibraryRequest:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .watchLibraryRequest
            case .watchLibrary:
                return .watchLibrary(try decoder.decode(WatchLibrary.self, from: payload))
            case .libraryMetadataRequest:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .libraryMetadataRequest
            case .libraryMetadataResponse:
                return .libraryMetadataResponse(
                    try decoder.decode(WatchLibraryMetadataResponse.self, from: payload)
                )
            case .playbackStateRequest:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .playbackStateRequest
            case .playbackState:
                return .playbackState(try decoder.decode(RemotePlaybackState.self, from: payload))
            case .noPlaybackState:
                _ = try decoder.decode(EmptyPayload.self, from: payload)
                return .noPlaybackState
            case .playbackCommand:
                return .playbackCommand(
                    try decoder.decode(RemotePlaybackCommand.self, from: payload)
                )
        }
    }
}

private struct EmptyPayload: Codable {}
