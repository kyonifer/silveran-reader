import Foundation
import WebKit

/// WebViewCommsBridge - Bridge for Swift-JS communication
///
/// Design principles:
/// - NO message wrapper/envelope pattern (no send<T> method)
/// - Swift calls JS directly via evaluateJavaScript
/// - JS calls Swift via webkit.messageHandlers
/// - Callbacks notify EbookPlayerView of events

@MainActor
class WebViewCommsBridge {
    weak var webView: WKWebView?

    // MARK: Callbacks if our user wants to be informed when these events occur

    /// Notifies when book structure (TOC) is ready
    var onBookStructureReady: ((BookStructureReadyMessage) -> Void)?

    /// Notifies when relocate event occurs (page turn, navigation, etc.)
    var onRelocated: ((RelocatedMessage) -> Void)?

    /// Notifies when user swipe gesture flips a page (iOS touch swipe detected by JS)
    var onPageFlipped: ((PageFlippedMessage) -> Void)?

    /// Notifies when user taps to toggle overlay (iOS only)
    var onOverlayToggled: (() -> Void)?

    /// Notifies when user clicks margin zone to navigate (routed through EPM)
    var onMarginClickNav: ((MarginClickNavMessage) -> Void)?

    /// Notifies when user double-clicks text to seek audio (or initial position)
    var onMediaOverlaySeek: ((MediaOverlaySeekMessage) -> Void)?

    /// Notifies when media overlay progress updates (audio playback progress)
    var onMediaOverlayProgress: ((MediaOverlayProgressMessage) -> Void)?

    /// Notifies when element visibility is reported (for page flip timing during audio)
    var onElementVisibility: ((ElementVisibilityMessage) -> Void)?

    // MARK: - Search callbacks

    /// Notifies when search finds results in a section
    var onSearchResults: ((SearchResultsMessage) -> Void)?

    /// Notifies of search progress (0.0-1.0)
    var onSearchProgress: ((SearchProgressMessage) -> Void)?

    /// Notifies when search is complete
    var onSearchComplete: (() -> Void)?

    /// Notifies when search encounters an error
    var onSearchError: ((SearchErrorMessage) -> Void)?

    init(webView: WKWebView? = nil) {
        self.webView = webView
    }

    /// JS is sending Swift a BookStructureReady event when book TOC is loaded
    func sendSwiftBookStructureReady(_ message: BookStructureReadyMessage) {
        debugLog(
            "[WebViewCommsBridge] sendSwiftBookStructureReady - \(message.sections.count) sections"
        )
        onBookStructureReady?(message)
    }

    /// JS is sending Swift a Relocated event when user navigates, page turns, resizes, etc.
    func sendSwiftRelocated(_ message: RelocatedMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftRelocated")
        debugLog(
            "[WebViewCommsBridge]   section: \(message.sectionIndex?.description ?? "nil"), page: \(message.pageIndex?.description ?? "nil")"
        )
        debugLog("[WebViewCommsBridge]   href: \(message.href ?? "nil")")
        debugLog("[WebViewCommsBridge]   cfi: \(message.cfi)")
        debugLog(
            "[WebViewCommsBridge]   fraction: \(message.fraction?.description ?? "nil"), chapterFraction: \(message.chapterFraction?.description ?? "nil")"
        )
        onRelocated?(message)
    }

    /// JS detected a user swipe that flipped the page
    func sendSwiftPageFlipped(_ message: PageFlippedMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftPageFlipped - direction: \(message.direction)")
        onPageFlipped?(message)
    }

    /// JS detected a user tap to toggle overlay visibility
    func sendSwiftOverlayToggled(_ message: OverlayToggledMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftOverlayToggled")
        onOverlayToggled?()
    }

    /// JS detected a margin click for navigation
    func sendSwiftMarginClickNav(_ message: MarginClickNavMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftMarginClickNav - direction: \(message.direction)")
        onMarginClickNav?(message)
    }

    /// JS detected a media overlay seek event (double-click or initial position)
    func sendSwiftMediaOverlaySeek(_ message: MediaOverlaySeekMessage) {
        debugLog(
            "[WebViewCommsBridge] sendSwiftMediaOverlaySeek - section: \(message.sectionIndex), anchor: \(message.anchor)"
        )
        onMediaOverlaySeek?(message)
    }

    /// JS is sending Swift a media overlay progress update (audio playback position)
    func sendSwiftMediaOverlayProgress(_ message: MediaOverlayProgressMessage) {
        debugLog(
            "[WebViewCommsBridge] sendSwiftMediaOverlayProgress - section: \(message.sectionIndex)"
        )
        onMediaOverlayProgress?(message)
    }

    /// JS is reporting element visibility for page flip timing during audio narration
    func sendSwiftElementVisibility(_ message: ElementVisibilityMessage) {
        debugLog(
            "[WebViewCommsBridge] sendSwiftElementVisibility - textId: \(message.textId), visible: \(message.visibleRatio), offScreen: \(message.offScreenRatio)"
        )
        onElementVisibility?(message)
    }

    // MARK: Swift commands JS to navigate left (previous page)
    func sendJsGoLeftCommand() async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog("[WebViewCommsBridge] sendJsGoLeftCommand()")
        _ = try await webView.evaluateJavaScript("window.foliateManager.goLeft()")
    }

    /// Swift commands JS to navigate right (next page)
    func sendJsGoRightCommand() async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog("[WebViewCommsBridge] sendJsGoRightCommand()")
        _ = try await webView.evaluateJavaScript("window.foliateManager.goRight()")
    }

    /// Swift commands JS to navigate to a specific href (with optional fragment)
    func sendJsGoToHrefCommand(href: String) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let escapedHref = href.replacingOccurrences(of: "'", with: "\\'")
        debugLog("[WebViewCommsBridge] sendJsGoToHrefCommand(href: \(href))")
        _ = try await webView.evaluateJavaScript("window.foliateManager.goTo('\(escapedHref)')")
    }

    /// Swift commands JS to navigate to a Readium locator (href + optional fragment)
    func sendJsGoToLocatorCommand(locator: BookLocator) async throws {
        var href = locator.href

        if let fragment = locator.locations?.fragments?.first {
            href = "\(href)#\(fragment)"
        }

        try await sendJsGoToHrefCommand(href: href)
    }

    /// Swift commands JS to navigate to a specific fraction within a section/chapter
    func sendJsGoToFractionInSectionCommand(sectionIndex: Int, fraction: Double) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog(
            "[WebViewCommsBridge] sendJsGoToFractionInSectionCommand(section: \(sectionIndex), fraction: \(fraction))"
        )

        // goToFractionInSection is async, so we wrap it in an IIFE that returns undefined immediately
        // We fire-and-forget - we'll get the result via the Relocated message
        _ = try await webView.evaluateJavaScript(
            "(function() { window.foliateManager.goToFractionInSection(\(sectionIndex), \(fraction)); })()"
        )
    }

    /// Swift commands JS to navigate to a book-wide fraction (0.0 - 1.0)
    /// Used when translating audio locators to text positions via totalProgression
    func sendJsGoToBookFractionCommand(fraction: Double) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog("[WebViewCommsBridge] sendJsGoToBookFractionCommand(fraction: \(fraction))")
        _ = try await webView.evaluateJavaScript(
            "(function() { window.foliateManager.goToBookFraction(\(fraction)); })()"
        )
    }

    /// Swift is requesting a current location from JS
    /// Returns: JSON object with sectionIndex, pageIndex, cfi, href, fraction
    func sendJsCurrentLocationRequest() async throws -> String? {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.foliateManager.getCurrentLocation())"
        )

        return result as? String
    }

    /// Swift is requesting fully visible element IDs from JS
    /// Returns: Array of element IDs that are fully contained in the current page range
    func sendJsGetFullyVisibleElementIds() async throws -> [String]? {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(window.foliateManager.getFullyVisibleElementIds())"
        )

        guard let jsonString = result as? String,
            let jsonData = jsonString.data(using: .utf8)
        else {
            return nil
        }

        let decoded = try? JSONDecoder().decode([String].self, from: jsonData)
        return decoded
    }

    // MARK: - Highlight controls (Swift controls audio directly)

    /// Swift commands JS to highlight a specific text fragment
    /// JS will apply highlight CSS and report visibility for page flip timing
    /// - Parameters:
    ///   - sectionIndex: The section index
    ///   - textId: The text element ID to highlight
    ///   - seekToLocation: If true, navigates the view to the element before highlighting
    func sendJsHighlightFragment(sectionIndex: Int, textId: String, seekToLocation: Bool = false) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let escapedTextId = textId.replacingOccurrences(of: "'", with: "\\'")
        debugLog("[WebViewCommsBridge] sendJsHighlightFragment(sectionIndex: \(sectionIndex), textId: \(textId), seekToLocation: \(seekToLocation))")
        _ = try await webView.evaluateJavaScript(
            "window.foliateManager.highlightFragment(\(sectionIndex), '\(escapedTextId)', \(seekToLocation))"
        )
    }

    /// Swift commands JS to clear any active highlight
    func sendJsClearHighlight() async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog("[WebViewCommsBridge] sendJsClearHighlight()")
        _ = try await webView.evaluateJavaScript("window.foliateManager.clearHighlight()")
    }

    /// Swift commands JS to update reader styles (font, colors, margins, etc.)
    func sendJsUpdateStyles(
        fontSize: Double,
        fontFamily: String,
        lineSpacing: Double,
        isDarkMode: Bool,
        marginLeftRight: Double,
        marginTopBottom: Double,
        wordSpacing: Double,
        letterSpacing: Double,
        highlightColor: String,
        backgroundColor: String?,
        foregroundColor: String?,
        customCSS: String?,
        singleColumnMode: Bool,
        enableMarginClickNavigation: Bool
    ) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        var styles: [String: Any] = [
            "fontSize": fontSize,
            "fontFamily": fontFamily,
            "lineSpacing": lineSpacing,
            "isDarkMode": isDarkMode,
            "marginLeftRight": marginLeftRight,
            "marginTopBottom": marginTopBottom,
            "wordSpacing": wordSpacing,
            "letterSpacing": letterSpacing,
            "highlightColor": highlightColor,
            "singleColumnMode": singleColumnMode,
            "enableMarginClickNavigation": enableMarginClickNavigation,
        ]

        styles["backgroundColor"] = backgroundColor ?? NSNull()
        styles["foregroundColor"] = foregroundColor ?? NSNull()
        if let customCSS = customCSS {
            styles["customCSS"] = customCSS
        }

        let jsonData = try JSONSerialization.data(withJSONObject: styles)
        let jsonString = String(data: jsonData, encoding: .utf8)!
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        debugLog("[WebViewCommsBridge] sendJsUpdateStyles()")
        let script = "window.foliateManager.updateStyles('\(jsonString)')"
        _ = try await webView.evaluateJavaScript(script)
    }

    // MARK: - Search dispatch methods (JS → Swift)

    func sendSwiftSearchResults(_ message: SearchResultsMessage) {
        debugLog(
            "[WebViewCommsBridge] sendSwiftSearchResults - \(message.results.count) results in \(message.sectionLabel)"
        )
        onSearchResults?(message)
    }

    func sendSwiftSearchProgress(_ message: SearchProgressMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftSearchProgress - \(message.progress)")
        onSearchProgress?(message)
    }

    func sendSwiftSearchComplete() {
        debugLog("[WebViewCommsBridge] sendSwiftSearchComplete")
        onSearchComplete?()
    }

    func sendSwiftSearchError(_ message: SearchErrorMessage) {
        debugLog("[WebViewCommsBridge] sendSwiftSearchError - \(message.message)")
        onSearchError?(message)
    }

    // MARK: - Search commands (Swift → JS)

    /// Swift commands JS to start a search
    func sendJsStartSearchCommand(
        query: String,
        matchCase: Bool = false,
        matchDiacritics: Bool = false,
        matchWholeWords: Bool = false
    ) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let escapedQuery =
            query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let options: [String: Any] = [
            "matchCase": matchCase,
            "matchDiacritics": matchDiacritics,
            "matchWholeWords": matchWholeWords,
        ]
        let optionsJson = try JSONSerialization.data(withJSONObject: options)
        let optionsString = String(data: optionsJson, encoding: .utf8)!

        debugLog("[WebViewCommsBridge] sendJsStartSearchCommand(query: \(query))")
        _ = try await webView.evaluateJavaScript(
            "(function() { window.foliateManager.startSearch('\(escapedQuery)', \(optionsString)); })()"
        )
    }

    /// Swift commands JS to clear search results
    func sendJsClearSearchCommand() async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        debugLog("[WebViewCommsBridge] sendJsClearSearchCommand()")
        _ = try await webView.evaluateJavaScript("window.foliateManager.clearSearch()")
    }

    /// Swift commands JS to navigate to a CFI (for search result navigation)
    func sendJsGoToCFICommand(cfi: String) async throws {
        guard let webView = webView else {
            throw WebViewCommsBridgeError.webViewNotAvailable
        }

        let escapedCFI =
            cfi
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        debugLog("[WebViewCommsBridge] sendJsGoToCFICommand(cfi: \(cfi))")
        _ = try await webView.evaluateJavaScript(
            "(function() { window.foliateManager.goToCFI('\(escapedCFI)'); })()"
        )
    }
}

enum WebViewCommsBridgeError: Error, LocalizedError {
    case webViewNotAvailable

    var errorDescription: String? {
        switch self {
            case .webViewNotAvailable:
                return "WebView is not available"
        }
    }
}
