import Foundation

public struct FolderSourceLibraryState: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceID: BookSourceID
    public var works: [FolderSourceWork]
    public var media: [FolderSourceMedia]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceID: BookSourceID,
        works: [FolderSourceWork] = [],
        media: [FolderSourceMedia] = [],
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.works = works
        self.media = media
    }
}

public struct FolderSourceWork: Codable, Sendable, Hashable, Identifiable {
    public var uuid: String
    public var title: String
    public var subtitle: String?
    public var description: String?
    public var language: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var publicationDate: String?
    public var authors: [BookCreator]?
    public var narrators: [BookCreator]?
    public var creators: [BookCreator]?
    public var series: [BookSeries]?
    public var tags: [BookTag]?
    public var collections: [BookCollectionSummary]?
    public var status: BookStatus?
    public var position: BookReadingPosition?
    public var rating: Double?
    public var mediaIDs: [FolderSourceMediaRole: String]
    public var groupingKey: String
    public var groupingReason: String?

    public var id: String { uuid }

    public init(
        uuid: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        language: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        publicationDate: String? = nil,
        authors: [BookCreator]? = nil,
        narrators: [BookCreator]? = nil,
        creators: [BookCreator]? = nil,
        series: [BookSeries]? = nil,
        tags: [BookTag]? = nil,
        collections: [BookCollectionSummary]? = nil,
        status: BookStatus? = nil,
        position: BookReadingPosition? = nil,
        rating: Double? = nil,
        mediaIDs: [FolderSourceMediaRole: String] = [:],
        groupingKey: String,
        groupingReason: String? = nil,
    ) {
        self.uuid = uuid
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publicationDate = publicationDate
        self.authors = authors
        self.narrators = narrators
        self.creators = creators
        self.series = series
        self.tags = tags
        self.collections = collections
        self.status = status
        self.position = position
        self.rating = rating
        self.mediaIDs = mediaIDs
        self.groupingKey = groupingKey
        self.groupingReason = groupingReason
    }
}

public enum FolderSourceMediaRole: String, Codable, Sendable, Hashable, CaseIterable {
    case ebook
    case readaloud
    case audio

    public var localMediaCategory: LocalMediaCategory {
        switch self {
            case .ebook:
                return .ebook
            case .readaloud:
                return .synced
            case .audio:
                return .audio
        }
    }
}

public struct FolderSourceMedia: Codable, Sendable, Hashable, Identifiable {
    public var uuid: String
    public var role: FolderSourceMediaRole
    public var relativePaths: [String]
    public var signature: FolderSourceMediaSignature
    public var extractedMetadata: BookMetadata?
    public var missing: Bool
    public var firstSeenAt: String?
    public var lastSeenAt: String?
    public var previousRelativePaths: [String]

    public var id: String { uuid }

    public init(
        uuid: String = UUID().uuidString,
        role: FolderSourceMediaRole,
        relativePaths: [String],
        signature: FolderSourceMediaSignature,
        extractedMetadata: BookMetadata? = nil,
        missing: Bool = false,
        firstSeenAt: String? = nil,
        lastSeenAt: String? = nil,
        previousRelativePaths: [String] = [],
    ) {
        self.uuid = uuid
        self.role = role
        self.relativePaths = relativePaths
        self.signature = signature
        self.extractedMetadata = extractedMetadata
        self.missing = missing
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.previousRelativePaths = previousRelativePaths
    }
}

public struct FolderSourceMediaSignature: Codable, Sendable, Hashable {
    public var fileCount: Int
    public var totalSize: Int64
    public var modifiedAt: [String: Double]

    public init(fileCount: Int, totalSize: Int64, modifiedAt: [String: Double]) {
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.modifiedAt = modifiedAt
    }
}
