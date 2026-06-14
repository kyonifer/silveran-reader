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
    forMainFrameOnly: false,
)

@available(macOS 14.0, iOS 17.0, *)
private func javaScriptStringLiteral(_ string: String) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: [string]),
        let arrayLiteral = String(data: data, encoding: .utf8)
    else {
        return "''"
    }

    return String(arrayLiteral.dropFirst().dropLast())
}

@available(macOS 14.0, iOS 17.0, *)
@MainActor
private func makeBookOpenScript(ebookPath: URL?) -> WKUserScript {
    let pathLiteral = ebookPath.map { javaScriptStringLiteral($0.path) } ?? "null"
    let isDirectory = ebookPath?.hasDirectoryPath == true ? "true" : "false"

    return WKUserScript(
        source: """
            (function() {
                window.silveranBookPath = \(pathLiteral);
                window.silveranBookIsDirectory = \(isDirectory);
                window.nativeReady = window.silveranBookPath !== null;
                window.jsReady = window.jsReady || false;
                window.silveranOpenedBookPath = window.silveranOpenedBookPath || null;
                window.silveranOpeningBookPath = window.silveranOpeningBookPath || null;

                window.tryOpenSilveranBook = function(reason) {
                    if (!window.nativeReady || !window.jsReady || !window.silveranBookPath) {
                        return false;
                    }

                    const loader = window.bookLoader;
                    if (!loader) {
                        window.jsReady = false;
                        return false;
                    }

                    if (window.silveranOpenedBookPath === window.silveranBookPath ||
                        window.silveranOpeningBookPath === window.silveranBookPath) {
                        return true;
                    }

                    window.silveranOpeningBookPath = window.silveranBookPath;
                    console.log('[SilveranBookOpen] opening book', reason, window.silveranBookPath);

                    const openPromise = window.silveranBookIsDirectory
                        ? loader.openBookFromDirectory(window.silveranBookPath)
                        : loader.openBook(window.silveranBookPath);

                    Promise.resolve(openPromise).then(function() {
                        window.silveranOpenedBookPath = window.silveranBookPath;
                        window.silveranOpeningBookPath = null;
                    }).catch(function(error) {
                        window.silveranOpeningBookPath = null;
                        console.error('[SilveranBookOpen] failed to open book', error);
                    });

                    return true;
                };

                window.tryOpenSilveranBook('nativeReady');
            })();
            """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
    )
}

@available(macOS 14.0, iOS 17.0, *)
private class WebViewCoordinator2: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let onNavigationFinished: () -> Void
    var commsBridge: WebViewCommsBridge?
    var onContentPurged: (() -> Void)?
    var onReaderReady: (() -> Void)?

    init(onNavigationFinished: @escaping () -> Void) {
        self.onNavigationFinished = onNavigationFinished
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        debugLog("[EbookPlayerWebView] Web content process terminated")
        onContentPurged?()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) {
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
                return

            case "ReaderReady":
                debugLog("[EbookPlayerWebView] Reader JS modules initialized")
                onReaderReady?()
                return

            default:
                break
        }

        guard let bridge = commsBridge else {
            debugLog(
                "[EbookPlayerWebView] CommsBridge not initialized for message: \(message.name)"
            )
            return
        }

        let decoder = JSONDecoder()

        do {
            switch message.name {
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

                case "SentenceSkip":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SentenceSkipMessage.self, from: data)
                    bridge.sendSwiftSentenceSkip(msg)

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

                case "SelectionHighlight":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionHighlightMessage.self, from: data)
                    bridge.sendSwiftSelectionHighlight(msg)

                case "SelectionDefine":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionTextActionMessage.self, from: data)
                    let term = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    #if os(macOS)
                    var rect: CGRect? = nil
                    if let x = msg.x, let y = msg.y, let w = msg.width, let h = msg.height {
                        rect = CGRect(x: x, y: y, width: w, height: h)
                    }
                    (message.webView as? HighlightableWebView)?
                        .presentDictionary(for: term, atViewportRect: rect)
                    #else
                    (message.webView as? HighlightableWebView)?.presentDictionary(for: term)
                    #endif

                case "SelectionShare":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionTextActionMessage.self, from: data)
                    let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var rect: CGRect? = nil
                    if let x = msg.x, let y = msg.y, let w = msg.width, let h = msg.height {
                        rect = CGRect(x: x, y: y, width: w, height: h)
                    }
                    (message.webView as? HighlightableWebView)?
                        .presentShare(for: text, atViewportRect: rect)

                case "SelectionTranslate":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionTextActionMessage.self, from: data)
                    bridge.sendSwiftSelectionTranslate(msg.text)

                case "SelectionSearch":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionTextActionMessage.self, from: data)
                    bridge.sendSwiftSelectionSearch(msg.text)

                case "SelectionCopy":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(SelectionTextActionMessage.self, from: data)
                    Self.copyToPasteboard(msg.text)

                case "HighlightSetColor":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(HighlightSetColorMessage.self, from: data)
                    bridge.sendSwiftHighlightSetColor(msg)

                case "HighlightDelete":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(HighlightDeleteMessage.self, from: data)
                    bridge.sendSwiftHighlightDelete(msg)

                case "HighlightEdit":
                    let data = try JSONSerialization.data(withJSONObject: message.body)
                    let msg = try decoder.decode(HighlightEditMessage.self, from: data)
                    bridge.sendSwiftHighlightEdit(msg)

                case "FileAccessDiagnostic":
                    if let body = message.body as? [String: Any],
                        let filePath = body["filePath"] as? String,
                        let errorMessage = body["errorMessage"] as? String
                    {
                        Self.runFileAccessDiagnostic(
                            filePath: filePath,
                            errorMessage: errorMessage,
                        )
                    }

                default:
                    debugLog("[EbookPlayerWebView] Unknown message type: \(message.name)")
            }
        } catch {
            debugLog("[EbookPlayerWebView] Failed to decode message '\(message.name)': \(error)")
        }
    }

    static func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        #else
        UIPasteboard.general.string = trimmed
        #endif
    }

    static func runFileAccessDiagnostic(filePath: String, errorMessage: String) {
        let fm = FileManager.default
        let tag = "[FileAccessDiagnostic]"

        debugLog("\(tag) JS fetch failed for: \(filePath)")
        debugLog("\(tag) JS error: \(errorMessage)")

        let exists = fm.fileExists(atPath: filePath)
        debugLog("\(tag) FileManager.fileExists: \(exists)")

        if exists {
            let readable = fm.isReadableFile(atPath: filePath)
            debugLog("\(tag) FileManager.isReadableFile: \(readable)")

            do {
                let attrs = try fm.attributesOfItem(atPath: filePath)
                let protection = attrs[.protectionKey] as? FileProtectionType
                let fileSize = attrs[.size] as? UInt64 ?? 0
                debugLog("\(tag) File size: \(fileSize) bytes")
                debugLog(
                    "\(tag) File protection: \(protection?.rawValue ?? "nil (inheriting default)")"
                )
            } catch {
                debugLog("\(tag) Failed to read file attributes: \(error)")
            }

            do {
                let data = try Data(
                    contentsOf: URL(fileURLWithPath: filePath),
                    options: .mappedIfSafe,
                )
                debugLog("\(tag) Swift Data(contentsOf:) succeeded, \(data.count) bytes")
            } catch {
                debugLog("\(tag) Swift Data(contentsOf:) FAILED: \(error)")
            }
        }

        #if os(iOS)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        debugLog("\(tag) isProtectedDataAvailable: \(protectedDataAvailable)")

        let availableMemory = os_proc_available_memory()
        debugLog("\(tag) os_proc_available_memory: \(availableMemory / 1_048_576) MB")
        #endif
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("[EbookPlayerWebView] Navigation finished successfully")
        onNavigationFinished()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error,
    ) {
        debugLog("[EbookPlayerWebView] Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error,
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

    func presentDictionary(for term: String) {
        guard !term.isEmpty,
            UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term),
            let presenter = nearestViewController()
        else { return }
        presenter.present(UIReferenceLibraryViewController(term: term), animated: true)
    }

    func presentShare(for text: String, atViewportRect rect: CGRect?) {
        guard !text.isEmpty, let presenter = nearestViewController() else { return }
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = self
            pop.sourceRect = rect ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        }
        presenter.present(activityVC, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return window?.rootViewController
    }

    // The compact in-page selection toolbar replaces the native callout menu entirely.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
        builder.remove(menu: .replace)
        builder.remove(menu: .learn)
    }
}
#endif

#if os(macOS)
@available(macOS 14.0, *)
class HighlightableWebView: WKWebView {
    var commsBridge: WebViewCommsBridge?

    func presentDictionary(for term: String, atViewportRect rect: CGRect?) {
        guard !term.isEmpty else { return }

        let point: NSPoint
        if let rect {
            // rect is top-left-origin viewport coords; flip if the view isn't flipped.
            var p = NSPoint(x: rect.midX, y: rect.maxY)
            if !isFlipped { p.y = bounds.height - p.y }
            point = p
        } else {
            point = NSPoint(x: bounds.midX, y: bounds.midY)
        }

        showDefinition(for: NSAttributedString(string: term), at: point)
    }

    func presentShare(for text: String, atViewportRect rect: CGRect?) {
        guard !text.isEmpty else { return }

        let anchor: NSRect
        if let rect {
            // rect is top-left-origin viewport coords; flip to bottom-left if needed.
            var r = rect
            if !isFlipped { r.origin.y = bounds.height - rect.maxY }
            anchor = r
        } else {
            anchor = NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        }

        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: anchor, of: self, preferredEdge: .minY)
    }
}
#endif

@available(macOS 14.0, iOS 17.0, *)
@MainActor
private func makeWebViewConfiguration2(
    coordinator: WebViewCoordinator2,
    ebookPath: URL?,
) -> WKWebViewConfiguration {
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
    contentController.add(coordinator, name: "SentenceSkip")
    contentController.add(coordinator, name: "mediaOverlaySeek")
    contentController.add(coordinator, name: "MediaOverlayProgress")
    contentController.add(coordinator, name: "ElementVisibility")
    contentController.add(coordinator, name: "SearchResults")
    contentController.add(coordinator, name: "SearchProgress")
    contentController.add(coordinator, name: "SearchComplete")
    contentController.add(coordinator, name: "SearchError")
    contentController.add(coordinator, name: "TextSelection")
    contentController.add(coordinator, name: "SelectionHighlight")
    contentController.add(coordinator, name: "SelectionDefine")
    contentController.add(coordinator, name: "SelectionShare")
    contentController.add(coordinator, name: "SelectionTranslate")
    contentController.add(coordinator, name: "SelectionSearch")
    contentController.add(coordinator, name: "SelectionCopy")
    contentController.add(coordinator, name: "HighlightSetColor")
    contentController.add(coordinator, name: "HighlightDelete")
    contentController.add(coordinator, name: "HighlightEdit")
    contentController.add(coordinator, name: "FileAccessDiagnostic")
    contentController.add(coordinator, name: "ReaderReady")

    contentController.addUserScript(consoleOverrideScript)
    contentController.addUserScript(makeBookOpenScript(ebookPath: ebookPath))
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
        onContentPurged: (() -> Void)? = nil,
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
            onContentPurged: onContentPurged,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct WebViewWrapper2: View {
    let ebookPath: URL?
    @Binding var commsBridge: WebViewCommsBridge?
    let onBridgeReady: ((WebViewCommsBridge) -> Void)?
    let onContentPurged: (() -> Void)?
    @State private var webView: WKWebView?

    var body: some View {
        WebViewRepresentable2(
            webView: $webView,
            commsBridge: $commsBridge,
            ebookPath: ebookPath,
            onBridgeReady: onBridgeReady,
            onReaderReady: {
                markJsReady(reason: "ReaderReady")
            },
            onContentPurged: onContentPurged,
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
            // can fetch EPUB files from sibling directories like SourceCache/
            webView.loadFileURL(
                url,
                allowingReadAccessTo: webResourcesDir.deletingLastPathComponent(),
            )
        }
    }

    private func markJsReady(reason: String) {
        guard let webView = webView else {
            debugLog("[EbookPlayerWebView] Cannot mark JS ready - webView is nil")
            return
        }

        Task { @MainActor in
            do {
                let reasonLiteral = javaScriptStringLiteral(reason)
                _ = try await webView.evaluateJavaScript(
                    "window.jsReady = true; window.tryOpenSilveranBook?.(\(reasonLiteral))"
                )
            } catch {
                debugLog("[EbookPlayerWebView] Failed to mark JS ready: \(error)")
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
    let onReaderReady: () -> Void
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
        let config = makeWebViewConfiguration2(
            coordinator: context.coordinator,
            ebookPath: ebookPath,
        )

        #if os(macOS)
        let wkWebView = HighlightableWebView(frame: .zero, configuration: config)
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

            wkWebView.commsBridge = bridge

            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                wkWebView.window?.makeFirstResponder(wkWebView)
            }
            #endif

        }

        return wkWebView
    }

    func makeCoordinator() -> WebViewCoordinator2 {
        let coordinator = WebViewCoordinator2(onNavigationFinished: {})
        coordinator.onReaderReady = onReaderReady
        coordinator.onContentPurged = onContentPurged
        return coordinator
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif
