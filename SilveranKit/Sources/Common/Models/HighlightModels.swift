import Foundation
import SwiftUI

public enum HighlightColor: String, Codable, Sendable, Hashable, CaseIterable {
    case yellow
    case blue
    case green
    case pink
    case orange
    case purple

    public var color: Color {
        switch self {
            case .yellow: return Color(red: 0.710, green: 0.722, blue: 0.243)
            case .blue: return Color(red: 0.306, green: 0.565, blue: 0.780)
            case .green: return Color(red: 0.098, green: 0.529, blue: 0.267)
            case .pink: return Color(red: 0.886, green: 0.369, blue: 0.639)
            case .orange: return Color(red: 0.808, green: 0.549, blue: 0.290)
            case .purple: return Color(red: 0.702, green: 0.400, blue: 1.0)
        }
    }

    public var hexColor: String {
        switch self {
            case .yellow: return "#B5B83E"
            case .blue: return "#4E90C7"
            case .green: return "#198744"
            case .pink: return "#E25EA3"
            case .orange: return "#CE8C4A"
            case .purple: return "#B366FF"
        }
    }
}

public struct Highlight: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let bookId: String
    public let locator: BookLocator
    public let text: String
    public let color: HighlightColor?
    public let note: String?
    public let createdAt: Date

    public var isBookmark: Bool {
        color == nil
    }

    public var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 97)
        return String(trimmed[..<endIndex]) + "..."
    }

    public var chapterTitle: String? {
        locator.title
    }

    public init(
        id: UUID = UUID(),
        bookId: String,
        locator: BookLocator,
        text: String,
        color: HighlightColor?,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.text = text
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }
}

public struct HighlightRenderData: Codable, Sendable {
    public let id: String
    public let sectionIndex: Int
    public let cfi: String
    public let color: String

    public init(id: String, sectionIndex: Int, cfi: String, color: String) {
        self.id = id
        self.sectionIndex = sectionIndex
        self.cfi = cfi
        self.color = color
    }
}

public struct BookHighlights: Codable, Sendable {
    public let bookId: String
    public var highlights: [Highlight]

    public init(bookId: String, highlights: [Highlight] = []) {
        self.bookId = bookId
        self.highlights = highlights
    }

    public var bookmarks: [Highlight] {
        highlights.filter { $0.isBookmark }
    }

    public var coloredHighlights: [Highlight] {
        highlights.filter { !$0.isBookmark }
    }
}
