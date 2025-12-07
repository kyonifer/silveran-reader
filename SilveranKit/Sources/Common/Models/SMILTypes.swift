import Foundation

/// Section info combining TOC data and SMIL metadata
public struct SectionInfo: Codable, Identifiable, Sendable {
    public let index: Int
    public let id: String
    public let label: String?
    public let level: Int?
    public let mediaOverlay: [SMILEntry]

    public init(
        index: Int,
        id: String,
        label: String?,
        level: Int?,
        mediaOverlay: [SMILEntry]
    ) {
        self.index = index
        self.id = id
        self.label = label
        self.level = level
        self.mediaOverlay = mediaOverlay
    }
}

/// SMIL media overlay entry with cumulative timing
public struct SMILEntry: Codable, Sendable {
    public let textId: String
    public let textHref: String
    public let audioFile: String
    public let begin: Double
    public let end: Double
    public let cumSumAtEnd: Double

    public init(
        textId: String,
        textHref: String,
        audioFile: String,
        begin: Double,
        end: Double,
        cumSumAtEnd: Double
    ) {
        self.textId = textId
        self.textHref = textHref
        self.audioFile = audioFile
        self.begin = begin
        self.end = end
        self.cumSumAtEnd = cumSumAtEnd
    }
}
