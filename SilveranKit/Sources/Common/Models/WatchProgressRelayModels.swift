import Foundation

public enum WatchProgressRelayMessage {
    public static let type = "progressSync"
    public static let typeKey = "type"
    public static let bookIdKey = "bookId"
    public static let timestampKey = "timestamp"
    public static let payloadKey = "payload"
}

public struct WatchProgressRelayPayload: Codable, Sendable {
    public let bookId: String
    /// The sender's sourceID is advisory only: BookSourceID is a per-device
    /// random UUID, so the receiver must re-resolve against its own registry.
    public let sourceID: BookSourceID?
    public let locator: BookLocator
    public let timestamp: Double

    public init(
        bookId: String,
        sourceID: BookSourceID?,
        locator: BookLocator,
        timestamp: Double,
    ) {
        self.bookId = bookId
        self.sourceID = sourceID
        self.locator = locator
        self.timestamp = timestamp
    }
}
