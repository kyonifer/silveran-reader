import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// EbookPlayerWebView - WebView integration for ebook reading
///
/// Handles messages from FoliateManager (see WebViewMessages.swift).

@available(macOS 14.0, iOS 17.0, *)
@MainActor
private let consoleOverrideScript = WKUserScript(
    source: """
        console.log = function(...args) {
            const message = args.map(arg => {
                if (typeof arg === 'object') {
                    try { return JSON.stringify(arg); }
                    catch { return String(arg); }
                }
                return String(arg);
            }).join(' ');
            window.webkit.messageHandlers.ConsoleLog.postMessage({level: 'log', message});
        };
        console.error = function(...args) {
            const message = args.map(arg => {
                if (arg instanceof Error) {
                    return 'Error: ' + arg.message + '\\n' + (arg.stack || '');
                }
                if (typeof arg === 'object') {
                    try { return JSON.stringify(arg); }
                    catch { return String(arg); }
                }
                return String(arg);
            }).join(' ');
            window.webkit.messageHandlers.ConsoleLog.postMessage({level: 'error', message});
        };
        console.warn = function(...args) {
            const message = args.map(arg => {
                if (typeof arg === 'object') {
                    try { return JSON.stringify(arg); }
                    catch { return String(arg); }
                }
                return String(arg);
            }).join(' ');
            window.webkit.messageHandlers.ConsoleLog.postMessage({level: 'warn', message});
        };
        window.addEventListener('error', function(e) {
            console.error('Global error:', e.error || e.message, 'at', e.filename, e.lineno, \
        e.colno);
        });
        window.addEventListener('unhandledrejection', function(e) {
            console.error('Unhandled promise rejection:', e.reason);
        });
        """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: false
)

@available(macOS 14.0, iOS 17.0, *)
private class WebViewCoordinator2: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let onNavigationFinished: () -> Void
    var commsBridge: WebViewCommsBridge?
    var onContentPurged: (() -> Void)?

    init(onNavigationFinished: @escaping () -> Void) {
        self.onNavigationFinished = onNavigationFinished
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        debugLog("[EbookPlayerWebView] Web content process terminated")
        onContentPurged?()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let bridge = commsBridge else {
            debugLog("[EbookPlayerWebView] CommsBridge not initialized")
            return
        }

        let decoder = JSONDecoder()

        do {
            switch message.name {
                case "ConsoleLog":
                    if let body = message.body as? [String: Any],
                        let level = body["level"] as? String,
                        let msg = body["message"] as? String
                    {
                        let prefix =
                            level == "error" ? "JS ERROR: " : level == "warn" ? "JS WARN: " : "JS: "
                        debugLog("[EbookPlayerWebView] \(prefix)\(msg)")
                    }

                case "BookStructureReady":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(BookStructureReadyMessage.self, from: data)
                    bridge.sendSwiftBookStructureReady(msg)

                case "Relocated":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(RelocatedMessage.self, from: data)
                    bridge.sendSwiftRelocated(msg)

                case "PageFlipped":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(PageFlippedMessage.self, from: data)
                    bridge.sendSwiftPageFlipped(msg)

                case "OverlayToggled":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(OverlayToggledMessage.self, from: data)
                    bridge.sendSwiftOverlayToggled(msg)

                case "MarginClickNav":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(MarginClickNavMessage.self, from: data)
                    bridge.sendSwiftMarginClickNav(msg)

                case "mediaOverlaySeek":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(MediaOverlaySeekMessage.self, from: data)
                    bridge.sendSwiftMediaOverlaySeek(msg)

                case "MediaOverlayProgress":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(MediaOverlayProgressMessage.self, from: data)
                    bridge.sendSwiftMediaOverlayProgress(msg)

                case "ElementVisibility":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(ElementVisibilityMessage.self, from: data)
                    bridge.sendSwiftElementVisibility(msg)

                case "SearchResults":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SearchResultsMessage.self, from: data)
                    bridge.sendSwiftSearchResults(msg)

                case "SearchProgress":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SearchProgressMessage.self, from: data)
                    bridge.sendSwiftSearchProgress(msg)

                case "SearchComplete":
                    bridge.sendSwiftSearchComplete()

                case "SearchError":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SearchErrorMessage.self, from: data)
                    bridge.sendSwiftSearchError(msg)

                case "TextSelection":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(TextSelectionMessage.self, from: data)
                    bridge.sendSwiftTextSelected(msg)

                case "HighlightTapped":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(HighlightTappedMessage.self, from: data)
                    bridge.sendSwiftHighlightTapped(msg)

                default:
                    debugLog("[EbookPlayerWebView] Unknown message type: \(message.name)")
            }
        } catch {
            debugLog("[EbookPlayerWebView] Failed to decode message '\(message.name)': \(error)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("[EbookPlayerWebView] Navigation finished successfully")
        onNavigationFinished()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        debugLog("[EbookPlayerWebView] Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        debugLog(
            "[EbookPlayerWebView] Provisional navigation failed: \(error.localizedDescription)"
        )
    }
}

#if os(iOS)
@available(iOS 17.0, *)
class HighlightableWebView: WKWebView {
    var commsBridge: WebViewCommsBridge?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(highlightSelection(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func highlightSelection(_ sender: Any?) {
        guard let bridge = commsBridge else { return }
        Task { @MainActor in
            do {
                try await bridge.sendJsCaptureCurrentSelection()
            } catch {
                debugLog("[HighlightableWebView] Failed to capture selection: \(error)")
            }
        }
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        let highlightAction = UIAction(
            title: "Highlight",
            image: UIImage(systemName: "highlighter")
        ) { [weak self] _ in
            self?.highlightSelection(nil)
        }

        let highlightMenu = UIMenu(title: "", options: .displayInline, children: [highlightAction])
        builder.insertChild(highlightMenu, atStartOfMenu: .standardEdit)
    }
}
#endif

@available(macOS 14.0, iOS 17.0, *)
@MainActor
private func makeWebViewConfiguration2(coordinator: WebViewCoordinator2) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    #endif

    let contentController = WKUserContentController()
    contentController.add(coordinator, name: "ConsoleLog")
    contentController.add(coordinator, name: "BookStructureReady")
    contentController.add(coordinator, name: "Relocated")
    contentController.add(coordinator, name: "PageFlipped")
    contentController.add(coordinator, name: "OverlayToggled")
    contentController.add(coordinator, name: "MarginClickNav")
    contentController.add(coordinator, name: "mediaOverlaySeek")
    contentController.add(coordinator, name: "MediaOverlayProgress")
    contentController.add(coordinator, name: "ElementVisibility")
    contentController.add(coordinator, name: "SearchResults")
    contentController.add(coordinator, name: "SearchProgress")
    contentController.add(coordinator, name: "SearchComplete")
    contentController.add(coordinator, name: "SearchError")
    contentController.add(coordinator, name: "TextSelection")
    contentController.add(coordinator, name: "HighlightTapped")

    contentController.addUserScript(consoleOverrideScript)
    config.userContentController = contentController

    return config
}

@available(macOS 14.0, iOS 17.0, *)
struct EbookPlayerWebView: View {
    let ebookPath: URL?
    @Binding var commsBridge: WebViewCommsBridge?
    let onBridgeReady: ((WebViewCommsBridge) -> Void)?
    let onContentPurged: (() -> Void)?

    init(
        ebookPath: URL?,
        commsBridge: Binding<WebViewCommsBridge?>,
        onBridgeReady: ((WebViewCommsBridge) -> Void)?,
        onContentPurged: (() -> Void)? = nil
    ) {
        self.ebookPath = ebookPath
        self._commsBridge = commsBridge
        self.onBridgeReady = onBridgeReady
        self.onContentPurged = onContentPurged
    }

    var body: some View {
        WebViewWrapper2(
            ebookPath: ebookPath,
            commsBridge: $commsBridge,
            onBridgeReady: onBridgeReady,
            onContentPurged: onContentPurged
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct WebViewWrapper2: View {
    let ebookPath: URL?
    @Binding var commsBridge: WebViewCommsBridge?
    let onBridgeReady: ((WebViewCommsBridge) -> Void)?
    let onContentPurged: (() -> Void)?
    @State private var webView: WKWebView?
    @State private var readerLoaded = false

    var body: some View {
        WebViewRepresentable2(
            webView: $webView,
            commsBridge: $commsBridge,
            ebookPath: ebookPath,
            onBridgeReady: onBridgeReady,
            onNavigationFinished: {
                if !readerLoaded {
                    readerLoaded = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        loadEpub()
                    }
                }
            },
            onContentPurged: onContentPurged
        )
        .onChange(of: webView) { oldValue, newValue in
            if newValue != nil {
                loadReader()
            }
        }
    }

    private func loadReader() {
        guard let webView = webView else {
            debugLog("[EbookPlayerWebView] WebView not ready yet")
            return
        }

        Task { @MainActor in
            let webResourcesDir = await FilesystemActor.shared.getWebResourcesDirectory()
            let url = webResourcesDir.appendingPathComponent("foliate_wrap.html")

            guard FileManager.default.fileExists(atPath: url.path) else {
                debugLog("[EbookPlayerWebView] ERROR: foliate_wrap.html not found at \(url.path)")
                return
            }

            debugLog("[EbookPlayerWebView] Loading foliate_wrap.html from: \(url)")
            debugLog(
                "[EbookPlayerWebView] Granting read access to: \(webResourcesDir.deletingLastPathComponent().path)"
            )
            // Grant access to Application Support (parent of WebResources) so that BookLoader.js
            // can fetch EPUB files from sibling directories like storyteller_media/
            webView.loadFileURL(
                url,
                allowingReadAccessTo: webResourcesDir.deletingLastPathComponent()
            )
        }
    }

    private func loadEpub() {
        guard let webView = webView, let ebookPath = ebookPath else {
            debugLog("[EbookPlayerWebView] Cannot load EPUB - webView or ebookPath is nil")
            return
        }

        Task { @MainActor in
            let escapedPath = ebookPath.path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            let script: String
            if ebookPath.hasDirectoryPath {
                debugLog("[EbookPlayerWebView] Loading EPUB from directory: \(ebookPath.path)")
                script = "window.bookLoader.openBookFromDirectory('\(escapedPath)')"
            } else {
                debugLog("[EbookPlayerWebView] Loading EPUB from file: \(ebookPath.path)")
                script = "window.bookLoader.openBook('\(escapedPath)')"
            }

            do {
                _ = try await webView.evaluateJavaScript(script)
                debugLog("[EbookPlayerWebView] EPUB load initiated successfully")
            } catch {
                debugLog("[EbookPlayerWebView] Failed to call bookLoader: \(error)")
            }
        }
    }
}

// MARK: - Platform-specific WebView Representable

@available(macOS 14.0, iOS 17.0, *)
private struct WebViewRepresentable2: PlatformViewRepresentable {
    @Binding var webView: WKWebView?
    @Binding var commsBridge: WebViewCommsBridge?
    let ebookPath: URL?
    let onBridgeReady: ((WebViewCommsBridge) -> Void)?
    let onNavigationFinished: () -> Void
    let onContentPurged: (() -> Void)?

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let config = makeWebViewConfiguration2(coordinator: context.coordinator)

        #if os(macOS)
        let wkWebView = WKWebView(frame: .zero, configuration: config)
        wkWebView.wantsLayer = true
        wkWebView.layer?.backgroundColor = .clear
        #else
        let wkWebView = HighlightableWebView(frame: .zero, configuration: config)
        wkWebView.isOpaque = false
        wkWebView.backgroundColor = .clear
        wkWebView.scrollView.backgroundColor = .clear
        #endif

        wkWebView.navigationDelegate = context.coordinator

        #if DEBUG
        wkWebView.isInspectable = true
        #endif

        DispatchQueue.main.async {
            self.webView = wkWebView
            let bridge = WebViewCommsBridge(webView: wkWebView)
            context.coordinator.commsBridge = bridge
            self.commsBridge = bridge
            self.onBridgeReady?(bridge)

            #if os(iOS)
            wkWebView.commsBridge = bridge
            #endif

            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                wkWebView.window?.makeFirstResponder(wkWebView)
            }
            #endif
        }

        return wkWebView
    }

    func makeCoordinator() -> WebViewCoordinator2 {
        let coordinator = WebViewCoordinator2(onNavigationFinished: onNavigationFinished)
        coordinator.onContentPurged = onContentPurged
        return coordinator
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif
