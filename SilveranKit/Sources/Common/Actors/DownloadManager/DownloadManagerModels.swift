import Foundation

public enum DownloadState: Codable, Sendable, Equatable {
    case queued
    case downloading(progress: Double)
    case paused(hasResumeData: Bool)
    case failed(error: String, hasResumeData: Bool)
    case importing
    case completed
}

public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let bookId: String
    public let sourceID: BookSourceID?
    public let category: LocalMediaCategory
    public let bookTitle: String
    public let format: StorytellerBookFormat

    public var state: DownloadState
    public var receivedBytes: Int64
    public var expectedBytes: Int64?
    public var retryCount: Int

    public let createdAt: Date
    public var lastUpdatedAt: Date

    public init(
        bookId: String,
        sourceID: BookSourceID? = nil,
        category: LocalMediaCategory,
        bookTitle: String,
        format: StorytellerBookFormat,
    ) {
        self.id = "\(bookId)-\(category.rawValue)"
        self.bookId = bookId
        self.sourceID = sourceID
        self.category = category
        self.bookTitle = bookTitle
        self.format = format
        self.state = .queued
        self.receivedBytes = 0
        self.expectedBytes = nil
        self.retryCount = 0
        self.createdAt = Date()
        self.lastUpdatedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bookId
        case sourceID
        case category
        case bookTitle
        case format
        case state
        case receivedBytes
        case expectedBytes
        case retryCount
        case createdAt
        case lastUpdatedAt
    }

    // Custom decoding so records persisted before retryCount existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.bookId = try container.decode(String.self, forKey: .bookId)
        self.sourceID = try container.decodeIfPresent(BookSourceID.self, forKey: .sourceID)
        self.category = try container.decode(LocalMediaCategory.self, forKey: .category)
        self.bookTitle = try container.decode(String.self, forKey: .bookTitle)
        self.format = try container.decode(StorytellerBookFormat.self, forKey: .format)
        self.state = try container.decode(DownloadState.self, forKey: .state)
        self.receivedBytes = try container.decode(Int64.self, forKey: .receivedBytes)
        self.expectedBytes = try container.decodeIfPresent(Int64.self, forKey: .expectedBytes)
        self.retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
    }

    public var progressFraction: Double {
        switch state {
            case .downloading(let progress):
                return progress
            case .completed:
                return 1.0
            default:
                guard let expected = expectedBytes, expected > 0 else { return 0 }
                return min(max(Double(receivedBytes) / Double(expected), 0), 1)
        }
    }

    public var isActive: Bool {
        switch state {
            case .queued, .downloading, .importing:
                return true
            default:
                return false
        }
    }

    public var isIncomplete: Bool {
        switch state {
            case .completed:
                return false
            default:
                return true
        }
    }
}

extension StorytellerBookFormat: Codable {}
