import Foundation
import Testing

@testable import SilveranKitAppModel
@testable import SilveranKitCommon
@testable import SilveranKitMacApp

@Test func publicationYearExtractsFourDigitYearFromSupportedDates() async throws {
    #expect(BookMetadata.publicationYear(from: "1950-01-02T00:00:00.000Z") == "1950")
    #expect(BookMetadata.publicationYear(from: "1987-09-16") == "1987")
    #expect(BookMetadata.publicationYear(from: " 1989-01-01T05:00:00.000Z ") == "1989")
    #expect(BookMetadata.publicationYear(from: "Unknown") == nil)
    #expect(BookMetadata.publicationYear(from: nil) == nil)
}

@Test func publicationYearSmartShelfNormalizesLegacyTimestampValues() async throws {
    let book = BookMetadata(
        uuid: "book-id",
        title: "Book",
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: "1950-01-02T00:00:00.000Z",
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

    let condition = ShelfCondition.publicationYear(
        mode: .include,
        values: ["1950-01-02T00:00:00.000Z"],
    )

    #expect(book.sortablePublicationYear == "1950")
    #expect(condition.matches(book, progress: 0))
}

@Test func publicationDateSortKeyUsesFullDateWithinYear() async throws {
    let january = makeBook(publicationDate: "1950-01-02T00:00:00.000Z")
    let september = makeBook(publicationDate: "1950-09-16")

    #expect(january.sortablePublicationYear == september.sortablePublicationYear)
    #expect(january.sortablePublicationDate < september.sortablePublicationDate)
}

@Test func alignedAtSortKeyAndParserUseRawAlignedDate() async throws {
    var book = makeBook(publicationDate: nil)
    book.alignedAt = "Mon Dec 15 2025 17:23:45 GMT+0100 (Central European Standard Time)"

    #expect(SilveranDate.parse(book.alignedAt, field: .alignedAt) != nil)
    #expect(book.sortableAlignedAt != "99999999999999")
}

@MainActor
@Test func smartShelfBooksUsePublishedDerivationSnapshot() async throws {
    let shelf = SmartShelf(name: "Recent", conditions: [])
    let book = makeBook(publicationDate: nil)
    let viewModel = MediaViewModel(
        injectLibrary: BookLibrary(
            bookMetaData: [book],
            ebookCoverCache: [:],
            audiobookCoverCache: [:],
        )
    )

    #expect(viewModel.booksForShelf(shelf).isEmpty)

    viewModel.libraryViewSnapshot = LibraryViewSnapshot(
        generation: 1,
        smartShelfBooks: [shelf.id: [book]],
    )

    #expect(viewModel.booksForShelf(shelf).map(\.id) == [book.id])
}

@Test func malformedLocatorFragmentsDecodeAsNoFragments() throws {
    let data = """
        {
          "uuid": "position-1",
          "timestamp": 1710000000000,
          "locator": {
            "href": "OEBPS/xhtml/30_Chapter_23_Resurrecti.xhtml",
            "type": "application/xhtml+xml",
            "locations": {
              "fragments": [
                {
                  "0": "c",
                  "1": "h",
                  "2": "a",
                  "3": "p"
                }
              ],
              "progression": 0.42,
              "totalProgression": 0.68
            }
          }
        }
        """.data(using: .utf8)!

    let position = try JSONDecoder().decode(BookReadingPosition.self, from: data)

    #expect(position.locator?.href == "OEBPS/xhtml/30_Chapter_23_Resurrecti.xhtml")
    #expect(position.locator?.locations?.fragments == nil)
    #expect(position.locator?.locations?.progression == 0.42)
    #expect(position.locator?.locations?.totalProgression == 0.68)
}

@Test func malformedLocatorDoesNotDropLibraryBook() throws {
    let data = """
        [
          {
            "uuid": "book-1",
            "title": "Still Visible",
            "position": {
              "uuid": "position-1",
              "timestamp": 1710000000000,
              "locator": {
                "href": { "unexpected": "object" },
                "type": "application/xhtml+xml",
                "locations": {
                  "totalProgression": 0.68
                }
              }
            }
          }
        ]
        """.data(using: .utf8)!

    let books = try JSONDecoder().decode(LenientArrayWrapper<BookMetadata>.self, from: data).values

    #expect(books.count == 1)
    #expect(books.first?.title == "Still Visible")
    #expect(books.first?.position?.locator == nil)
}

@Test func formURLEncodedBodyEscapesFormUnsafeCharacters() async throws {
    let body = formURLEncodedBody(["password": ">-\",+&= a"])
    let encoded = try #require(body.flatMap { String(data: $0, encoding: .utf8) })
    #expect(encoded == "password=%3E-%22,%2B%26%3D%20a")
}

@Test func folderSourceLibraryStateRoundTripsWorksMediaAndProgress() async throws {
    let root = try makeTemporaryFolderSource()
    defer { try? FileManager.default.removeItem(at: root) }
    let position = BookReadingPosition(
        uuid: "position-id",
        locator: nil,
        timestamp: 123,
        createdAt: nil,
        updatedAt: nil,
    )
    let state = FolderSourceLibraryState(
        sourceID: "source-id",
        works: [
            FolderSourceWork(
                uuid: "work-id",
                title: "Stable Book",
                position: position,
                mediaIDs: [.audio: "media-id"],
                groupingKey: "Stable Book/stable book",
            )
        ],
        media: [
            FolderSourceMedia(
                uuid: "media-id",
                role: .audio,
                relativePaths: [
                    "Stable Book/Stable Book 01.mp3", "Stable Book/Stable Book 02.mp3",
                ],
                signature: FolderSourceMediaSignature(
                    fileCount: 2,
                    totalSize: 6,
                    modifiedAt: ["Stable Book/Stable Book 01.mp3": 1],
                ),
            )
        ],
    )

    try await FilesystemActor().saveFolderSourceLibraryState(state, in: root)
    let loaded = try #require(try await FilesystemActor().loadFolderSourceLibraryState(in: root))

    #expect(loaded.schemaVersion == FolderSourceLibraryState.currentSchemaVersion)
    #expect(loaded.sourceID == "source-id")
    #expect(loaded.works.first?.uuid == "work-id")
    #expect(loaded.works.first?.position?.timestamp == 123)
    #expect(loaded.works.first?.mediaIDs[.audio] == "media-id")
    #expect(loaded.media.first?.relativePaths.count == 2)
}

@Test func audiobookActorLoadsManifestWithAbsoluteFileHrefs() async throws {
    let root = try makeTemporaryFolderSource()
    defer { try? FileManager.default.removeItem(at: root) }
    let audioURL = root.appendingPathComponent("Track 01.mp3", isDirectory: false)
    try Data([0]).write(to: audioURL)
    let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
    let manifest = """
        {
          "metadata": {
            "title": "Absolute Audio",
            "duration": 12
          },
          "readingOrder": [
            {
              "href": "\(audioURL.absoluteString)",
              "type": "audio/mpeg",
              "duration": 12
            }
          ],
          "toc": [
            {
              "href": "\(audioURL.absoluteString)#t=0",
              "title": "Track 1"
            }
          ]
        }
        """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

    let metadata = try await AudiobookActor.shared.validateAndLoadAudiobook(url: manifestURL)

    #expect(metadata.title == "Absolute Audio")
    #expect(metadata.tracks.first?.url == audioURL)
    #expect(metadata.tracks.first?.href == audioURL.absoluteString)
    #expect(metadata.totalDuration == 12)
}

@Test func folderSourceDerivedAudiobookManifestsCanBeInvalidatedBySource() async throws {
    let filesystem = FilesystemActor()
    let directory = await filesystem.folderSourceDerivedAudiobookDirectory(
        sourceID: "test-source",
        bookID: "test-book",
    )
    try await filesystem.ensureDirectoryExists(at: directory)
    let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
    try "{}".write(to: manifestURL, atomically: true, encoding: .utf8)
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))

    try await filesystem.removeFolderSourceDerivedAudiobooks(sourceID: "test-source")

    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
}

@Test func folderSourceGroupsSupportedMediaTypeSubfoldersAsOneWork() async throws {
    let root = try makeTemporaryFolderSource()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("A Matched Book", isDirectory: true)
    let audio = work.appendingPathComponent("audio", isDirectory: true)
    let ebook = work.appendingPathComponent("ebook", isDirectory: true)
    let synced = work.appendingPathComponent("synced", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ebook, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
    try Data([0]).write(to: audio.appendingPathComponent("Different Audio Name.mp3"))
    try Data([0]).write(to: ebook.appendingPathComponent("Different Ebook Name.epub"))
    try Data([0]).write(to: synced.appendingPathComponent("Different Readaloud Name.epub"))

    let source = BookSourceRecord(
        id: "folder-source",
        name: "Folder",
        kind: .localFolder,
        capabilities: .localFolder,
        storagePath: root.path,
    )
    let metadata = try await FolderSourceActor(sourceRecord: source).debugScanLibrary(in: root)

    #expect(metadata.count == 1)
    let book = try #require(metadata.first)
    #expect(book.title == "A Matched Book")
    #expect(book.ebook != nil)
    #expect(book.audiobook != nil)
    #expect(book.readaloud != nil)
}

@Test func folderSourceSplitsMixedCollectionFolderByPrefix() async throws {
    let root = try makeTemporaryFolderSource()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0]).write(to: root.appendingPathComponent("Book One.epub"))
    try Data([0]).write(to: root.appendingPathComponent("Book One 01.mp3"))
    try Data([0]).write(to: root.appendingPathComponent("Book One 02.mp3"))
    try Data([0]).write(to: root.appendingPathComponent("Book Two.epub"))
    try Data([0]).write(to: root.appendingPathComponent("Book Two 01.mp3"))

    let source = BookSourceRecord(
        id: "folder-source",
        name: "Folder",
        kind: .localFolder,
        capabilities: .localFolder,
        storagePath: root.path,
    )
    let metadata = try await FolderSourceActor(sourceRecord: source).debugScanLibrary(in: root)
    let byTitle = Dictionary(uniqueKeysWithValues: metadata.map { ($0.title, $0) })

    #expect(metadata.count == 2)
    #expect(byTitle["Book One"]?.ebook != nil)
    #expect(byTitle["Book One"]?.audiobook != nil)
    #expect(byTitle["Book Two"]?.ebook != nil)
    #expect(byTitle["Book Two"]?.audiobook != nil)
}

private func makeBook(publicationDate: String?) -> BookMetadata {
    BookMetadata(
        uuid: UUID().uuidString,
        title: "Book",
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: publicationDate,
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
}

private func makeTemporaryFolderSource() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SilveranKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
