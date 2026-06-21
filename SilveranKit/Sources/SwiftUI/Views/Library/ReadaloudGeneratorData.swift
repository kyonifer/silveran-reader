import Foundation
import SilveranKitCommon

extension Notification.Name {
    public static let silveranCreateReadaloud = Notification.Name("silveranCreateReadaloud")
}

public enum ReadaloudGeneratorDestination: String, Codable, Hashable, Sendable {
    case file
    case source
}

public struct ReadaloudGeneratorData: Codable, Hashable, Sendable, Identifiable {
    public var id: String { bookID }
    public let bookID: String
    public let bookTitle: String
    public let sourceID: BookSourceID?
    public let sourceName: String
    public let sourceKind: BookSourceKind?
    public let destination: ReadaloudGeneratorDestination
    public let ebookURL: URL?
    public let audioURLs: [URL]

    private enum CodingKeys: String, CodingKey {
        case bookID
        case bookTitle
        case sourceID
        case sourceName
        case sourceKind
        case destination
        case ebookURL
        case audioURL
        case audioURLs
    }

    public init(
        bookID: String,
        bookTitle: String,
        sourceID: BookSourceID?,
        sourceName: String,
        sourceKind: BookSourceKind?,
        destination: ReadaloudGeneratorDestination,
        ebookURL: URL?,
        audioURLs: [URL],
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.destination = destination
        self.ebookURL = ebookURL
        self.audioURLs = audioURLs
    }

    public init(
        bookID: String,
        bookTitle: String,
        sourceID: BookSourceID?,
        sourceName: String,
        sourceKind: BookSourceKind?,
        destination: ReadaloudGeneratorDestination,
        ebookURL: URL?,
        audioURL: URL?,
    ) {
        self.init(
            bookID: bookID,
            bookTitle: bookTitle,
            sourceID: sourceID,
            sourceName: sourceName,
            sourceKind: sourceKind,
            destination: destination,
            ebookURL: ebookURL,
            audioURLs: audioURL.map { [$0] } ?? [],
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try container.decode(String.self, forKey: .bookID)
        bookTitle = try container.decode(String.self, forKey: .bookTitle)
        sourceID = try container.decodeIfPresent(BookSourceID.self, forKey: .sourceID)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        sourceKind = try container.decodeIfPresent(BookSourceKind.self, forKey: .sourceKind)
        destination = try container.decode(
            ReadaloudGeneratorDestination.self,
            forKey: .destination,
        )
        ebookURL = try container.decodeIfPresent(URL.self, forKey: .ebookURL)
        if let decodedAudioURLs = try container.decodeIfPresent([URL].self, forKey: .audioURLs) {
            audioURLs = decodedAudioURLs
        } else if let decodedAudioURL = try container.decodeIfPresent(URL.self, forKey: .audioURL) {
            audioURLs = [decodedAudioURL]
        } else {
            audioURLs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookID, forKey: .bookID)
        try container.encode(bookTitle, forKey: .bookTitle)
        try container.encodeIfPresent(sourceID, forKey: .sourceID)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(sourceKind, forKey: .sourceKind)
        try container.encode(destination, forKey: .destination)
        try container.encodeIfPresent(ebookURL, forKey: .ebookURL)
        try container.encode(audioURLs, forKey: .audioURLs)
    }
}
