import Foundation
import Testing

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
