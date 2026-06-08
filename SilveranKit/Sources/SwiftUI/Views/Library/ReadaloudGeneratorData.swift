import Foundation
import SilveranKitCommon

public enum ReadaloudGeneratorDestination: String, Codable, Hashable, Sendable {
    case file
    case source
}

public struct ReadaloudGeneratorData: Codable, Hashable, Sendable {
    public let bookID: String
    public let bookTitle: String
    public let sourceID: BookSourceID?
    public let sourceName: String
    public let sourceKind: BookSourceKind?
    public let destination: ReadaloudGeneratorDestination
    public let ebookURL: URL?
    public let audioURL: URL?

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
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.destination = destination
        self.ebookURL = ebookURL
        self.audioURL = audioURL
    }
}
