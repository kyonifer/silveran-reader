#if os(iOS) || os(macOS)
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
    let flow: String?
    let reason: String?
}

/// Sent from JS when book structure is ready after opening a book
struct BookStructureReadyMessage: Codable {
    let sections: [SectionInfo]
}

/// Sent when foliate detects a user gesture that flips a page
struct PageFlippedMessage: Codable {
    let direction: String
    let fromPage: Int?
    let delta: Int?
}

/// Sent when user taps to toggle overlay visibility (iOS only)
struct OverlayToggledMessage: Codable {
}

/// Sent when user clicks in margin zone to navigate - routed through EPM like arrow keys
struct MarginClickNavMessage: Codable {
    let direction: String
}

/// Sent when WebView-owned key handling should skip readaloud sentences
struct SentenceSkipMessage: Codable {
    let direction: String
}

/// Sent when user double-clicks text to seek audio to that location
struct MediaOverlaySeekMessage: Codable {
    let sectionIndex: Int
    let anchor: String
    let startPlayback: Bool?
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

/// Sent from JS when search encounters an error
struct SearchErrorMessage: Codable {
    let message: String
}

// MARK: - Highlight Messages

/// Sent from JS when user completes a text selection (after long-press)
struct TextSelectionMessage: Codable {
    let sectionIndex: Int
    let cfi: String
    let text: String
    let href: String
    let title: String?
    let startCssSelector: String
    let startTextNodeIndex: Int
    let startCharOffset: Int
    let endCssSelector: String
    let endTextNodeIndex: Int
    let endCharOffset: Int
}

/// Sent from JS when a selection-toolbar swatch is tapped (mirrors TextSelectionMessage + colorId)
struct SelectionHighlightMessage: Codable {
    let sectionIndex: Int
    let cfi: String
    let text: String
    let href: String
    let title: String?
    let startCssSelector: String
    let startTextNodeIndex: Int
    let startCharOffset: Int
    let endCssSelector: String
    let endTextNodeIndex: Int
    let endCharOffset: Int
    let colorId: String

    var selection: TextSelectionMessage {
        TextSelectionMessage(
            sectionIndex: sectionIndex,
            cfi: cfi,
            text: text,
            href: href,
            title: title,
            startCssSelector: startCssSelector,
            startTextNodeIndex: startTextNodeIndex,
            startCharOffset: startCharOffset,
            endCssSelector: endCssSelector,
            endTextNodeIndex: endTextNodeIndex,
            endCharOffset: endCharOffset,
        )
    }
}

/// Sent from JS for a plain-text selection action (dictionary lookup / copy).
/// Rect fields (top-document viewport coords) are present for dictionary lookup
/// so macOS can anchor its definition popover at the selection.
struct SelectionTextActionMessage: Codable {
    let text: String
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
}

/// Sent from JS to recolor an existing highlight from the toolbar
struct HighlightSetColorMessage: Codable {
    let id: String
    let colorId: String
}

/// Sent from JS to delete an existing highlight from the toolbar
struct HighlightDeleteMessage: Codable {
    let id: String
}

/// Sent from JS to edit an existing highlight (color/note) from the toolbar
struct HighlightEditMessage: Codable {
    let id: String
}

/// Response from getFirstVisiblePosition() for bookmark creation
struct FirstVisiblePosition: Codable {
    let cfi: String?
    let text: String
    let href: String
    let title: String?
    let elementId: String?
}

#endif
