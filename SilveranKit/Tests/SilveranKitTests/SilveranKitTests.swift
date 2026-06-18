import Foundation
import Testing

@testable import SilveranKitCommon
@testable import SilveranKitAppModel
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
        injectLibrary: BookLibrary(bookMetaData: [book], ebookCoverCache: [:], audiobookCoverCache: [:])
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
