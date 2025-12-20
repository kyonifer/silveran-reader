import Foundation

/// WebViewMessages - Message definitions for FoliateManager
///
/// Design:
/// - Swift → JS: No wrapper needed, direct evaluateJavaScript calls
/// - JS → Swift: Simple structs decoded from webkit.messageHandlers

// MARK: - Messages from JS to Swift

/// Sent from JS when foliate-view relocates (page turn, navigation, etc.)
struct RelocatedMessage: Codable {
    let sectionIndex: Int?
    let pageIndex: Int?
    let totalPages: Int?
    let href: String?
    let cfi: String
    let fraction: Double?
    let chapterFraction: Double?
    let title: String?
}

/// Sent from JS when book structure is ready after opening a book
struct BookStructureReadyMessage: Codable {
    let sections: [SectionInfo]
}

/// Sent when foliate detects a user gesture that flips a page
struct PageFlippedMessage: Codable {
    let direction: String
    let fromPage: Int?
    let toPage: Int?
    let delta: Int?
    let isRtl: Bool
}

/// Sent when user taps to toggle overlay visibility (iOS only)
struct OverlayToggledMessage: Codable {
}

/// Sent when user clicks in margin zone to navigate - routed through EPM like arrow keys
struct MarginClickNavMessage: Codable {
    let direction: String
}

/// Sent when user double-clicks text to seek audio to that location
struct MediaOverlaySeekMessage: Codable {
    let sectionIndex: Int
    let anchor: String
}

// SectionInfo and SMILEntry are defined in Common/Models/SMILTypes.swift

/// Sent when media overlay makes progress during audio playback
struct MediaOverlayProgressMessage: Codable {
    let sectionIndex: Int
    let chapterElapsedSeconds: Double?
    let chapterTotalSeconds: Double?
    let bookElapsedSeconds: Double?
    let bookTotalSeconds: Double?
    let currentFragment: String?
}

/// Sent from JS when a highlighted element's visibility is calculated
/// Used for determining when to flip pages during audio narration
struct ElementVisibilityMessage: Codable {
    let textId: String
    let visibleRatio: Double
    let offScreenRatio: Double
}

// MARK: - Search Messages

/// Sent from JS when search finds results in a section
struct SearchResultsMessage: Codable {
    let sectionLabel: String
    let results: [SearchResult]
}

/// Individual search result with excerpt context
struct SearchResult: Codable, Identifiable, Hashable {
    let cfi: String
    let pre: String
    let match: String
    let post: String

    var id: String { cfi }
}

/// Sent from JS to report search progress (0.0-1.0)
struct SearchProgressMessage: Codable {
    let progress: Double
}

/// Sent from JS when search is complete
struct SearchCompleteMessage: Codable {}

/// Sent from JS when search encounters an error
struct SearchErrorMessage: Codable {
    let message: String
}
