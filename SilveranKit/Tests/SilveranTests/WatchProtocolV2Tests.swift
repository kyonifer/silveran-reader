import Foundation
import Testing

@testable import SilveranKit

@Test func watchProtocolRoundTripsTypedProgressEnvelope() throws {
    let bookID = BookID(sourceID: "source-a", uuid: "shared-book")
    let locator = BookLocator(
        href: "chapter.xhtml",
        type: "text/html",
        title: nil,
        locations: nil,
        text: nil,
    )
    let original = WatchProtocolMessage.progress(
        WatchProgressPayload(bookID: bookID, locator: locator, timestamp: 42)
    )

    let envelope = try original.encode()

    #expect(envelope[WatchProtocolV2.versionKey] as? Int == 2)
    #expect(envelope[WatchProtocolV2.typeKey] as? String == "progress")
    #expect(envelope[WatchProtocolV2.payloadKey] is Data)
    #expect(try WatchProtocolMessage.decode(from: envelope) == original)
}

@Test func watchProtocolRejectsWrongVersionBeforePayloadDecode() throws {
    let envelope: [String: Any] = [
        WatchProtocolV2.versionKey: 1,
        WatchProtocolV2.typeKey: WatchProtocolMessage.Kind.progress.rawValue,
        WatchProtocolV2.payloadKey: Data("not json".utf8),
    ]

    #expect(throws: WatchProtocolError.unsupportedVersion(1)) {
        try WatchProtocolMessage.decode(from: envelope)
    }
}

@Test func watchBookIdentityIncludesSourceAndCategory() {
    let firstSource = WatchBookInfo.ID(
        bookID: BookID(sourceID: "source-a", uuid: "shared"),
        category: .ebook,
    )
    let secondSource = WatchBookInfo.ID(
        bookID: BookID(sourceID: "source-b", uuid: "shared"),
        category: .ebook,
    )
    let secondCategory = WatchBookInfo.ID(
        bookID: BookID(sourceID: "source-a", uuid: "shared"),
        category: .audio,
    )

    #expect(Set([firstSource, secondSource, secondCategory]).count == 3)
}

@Test func watchProtocolRoundTripsRequiredChunkIdentityAndMetadata() throws {
    let bookID = BookID(sourceID: "source-a", uuid: "book-a")
    let metadata = BookMetadata(
        bookID: bookID,
        title: "Book",
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: nil,
        authors: nil,
        narrators: nil,
        creators: nil,
        series: nil,
        tags: nil,
        collections: nil,
        ebook: nil,
        audiobook: nil,
        readaloud: nil,
        status: nil,
        position: nil,
        rating: nil,
    )
    let transferID = UUID()
    let original = WatchProtocolMessage.chunkTransfer(
        WatchChunkTransferPayload(
            transferID: transferID,
            bookID: bookID,
            category: .ebook,
            chunkIndex: 0,
            totalChunks: 2,
            totalFileSize: 100,
            fileExtension: "epub",
            title: "Book",
            authors: ["Author"],
            bookMetadata: metadata,
        )
    )

    #expect(try WatchProtocolMessage.decode(from: original.encode()) == original)
}

@Test func remotePlaybackCommandUsesTypedCodablePayload() throws {
    let original = WatchProtocolMessage.playbackCommand(.seekToChapter(sectionIndex: 7))

    #expect(try WatchProtocolMessage.decode(from: original.encode()) == original)
}
