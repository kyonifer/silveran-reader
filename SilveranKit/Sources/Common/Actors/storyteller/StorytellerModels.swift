import Foundation

struct AccessToken: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int64?
}
struct StorytellerCollectionUser: Codable {
    let id: String
    let email: String?
    let username: String?
}

struct StorytellerCollection: Decodable {
    let uuid: String
    let name: String
    let description: String?
    let isPublic: Bool
    let importPath: String?
    let createdAt: String?
    let updatedAt: String?
    let users: [StorytellerCollectionUser]?

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case description
        case isPublic = "public"
        case importPath
        case createdAt
        case updatedAt
        case users
    }
}

struct StorytellerCoverUpload {
    let filename: String
    let data: Data
    let contentType: String?
}

struct StorytellerCreatorRelationUpdate: Codable {
    let uuid: String?
    let id: Int?
    let name: String
    let fileAs: String
    let role: String?
}

struct StorytellerSeriesRelationUpdate: Codable {
    let uuid: String?
    let name: String
    let featured: Bool?
    let position: Int?
}

struct StorytellerBookAssetRelationUpdate: Codable {
    let filepath: String?
    let missing: Int?
}

struct StorytellerReadaloudRelationUpdate: Codable {
    let filepath: String?
    let missing: Int?
    let status: String?
    let currentStage: String?
    let stageProgress: Double?
    let queuePosition: Int?
    let restartPending: Int?
}

struct StorytellerStatusRelationUpdate: Codable {
    let statusUuid: String
    let userId: String?
}

struct StorytellerBookRelationsUpdatePayload: Codable {
    var creators: [StorytellerCreatorRelationUpdate]?
    var series: [StorytellerSeriesRelationUpdate]?
    var collections: [String]?
    var tags: [String]?
    var ebook: StorytellerBookAssetRelationUpdate?
    var audiobook: StorytellerBookAssetRelationUpdate?
    var readaloud: StorytellerReadaloudRelationUpdate?
    var books: [String]?
    var status: StorytellerStatusRelationUpdate?
}

struct StorytellerBookMergeUpdate: Codable {
    var title: String?
    var subtitle: String?
    var language: String?
    var publicationDate: String?
    var description: String?
    var rating: Double?
}

struct StorytellerBookUpdatePayload {
    let uuid: String
    var title: String?
    var subtitle: String?
    var language: String?
    var publicationDate: String?
    var description: String?
    var rating: Double?
    var status: String?
    var authors: [String]?
    var narrators: [String]?
    var creators: [StorytellerCreatorRelationUpdate]?
    var series: [StorytellerSeriesRelationUpdate]?
    var collections: [String]?
    var tags: [String]?
}

struct StorytellerCollectionCreatePayload: Codable {
    let name: String
    let description: String
    let isPublic: Bool
    let users: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case isPublic = "public"
        case users
    }
}

struct StorytellerCollectionUpdatePayload: Codable {
    var name: String?
    var description: String?
    var isPublic: Bool?
    var users: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case isPublic = "public"
        case users
    }
}

enum StorytellerIncludeAssetsOption: String {
    case internalOnly = "internal"
    case all
}

enum StorytellerDownloadEvent: Sendable {
    case response(
        filename: String,
        expectedBytes: Int64?,
        contentType: String?,
        etag: String?,
        lastModified: String?
    )
    case progress(receivedBytes: Int64, expectedBytes: Int64?)
    case finished(temporaryURL: URL)
}

enum StorytellerDownloadFailure: Error, Sendable {
    case nonHTTPResponse
    case unauthorized
    case notFound
    case unexpectedStatus(Int)
}

struct StorytellerBookDownload: Sendable {
    let initialFilename: String
    let events: AsyncThrowingStream<StorytellerDownloadEvent, Error>
    let cancel: @Sendable () -> Void
}

enum StorytellerBookFormat: String, Sendable {
    case ebook
    case audiobook
    case readaloud
}

struct StorytellerUploadAsset {
    let format: StorytellerBookFormat
    let filename: String
    let data: Data
    let contentType: String? = nil
    let relativePath: String? = nil
}
