// Android reader orchestration: plays the role EbookPlayerViewModel has on
// Apple platforms, wrapping the shared ReadingSession + ReaderCommsBridge
// stack for a Kotlin-owned WebView.
import Foundation
import Observation
import SilveranKit

@SilveranUIActor
final class AndroidJSEvaluator: JSEvaluating {
    private var pending: [String: CheckedContinuation<String?, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var isClosed = false

    nonisolated init() {}

    @discardableResult
    func evaluate(_ script: String) async throws -> String? {
        guard !isClosed else {
            throw ReaderCommsBridgeError.jsNotAvailable
        }

        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            timeouts[requestID] = Task { @SilveranUIActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.complete(requestID: requestID, result: "", error: "JS evaluation timed out")
            }
            notifyAndroidEvaluateReaderJS(requestID: requestID, script: script)
        }
    }

    func complete(requestID: String, result: String, error: String) {
        timeouts.removeValue(forKey: requestID)?.cancel()
        guard let continuation = pending.removeValue(forKey: requestID) else { return }

        if !error.isEmpty {
            continuation.resume(throwing: AndroidBridgeError.readerJSFailed(error))
        } else {
            continuation.resume(returning: Self.normalizeEvalResult(result))
        }
    }

    func close() {
        isClosed = true
        for task in timeouts.values {
            task.cancel()
        }
        timeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: ReaderCommsBridgeError.jsNotAvailable)
        }
    }

    // Chromium's evaluateJavascript returns the result JSON-encoded ("null",
    // "\"text\"", "2", ...). WKWebView hands back the raw value and the Apple
    // adapter keeps only strings; decode one layer and do the same.
    private nonisolated static func normalizeEvalResult(_ raw: String) -> String? {
        if raw.isEmpty || raw == "null" || raw == "undefined" {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8),
                options: [.fragmentsAllowed],
            )
        else {
            return raw
        }
        return object as? String
    }
}

@SilveranUIActor
@Observable
final class AndroidReaderSettings: ReaderSettingsReading {
    var fontSize: Double = 16
    var fontFamily: String = "system"
    var lineSpacing: Double = 1.5
    var marginLeftRight: Double = kDefaultMarginLeftRightIOS
    var marginTopBottom: Double = kDefaultMarginTopBottom
    var wordSpacing: Double = 0
    var letterSpacing: Double = 0
    var textAlignment: String = "left"
    var highlightColor: String? = nil
    var highlightThickness: Double = 1
    var backgroundColor: String? = nil
    var foregroundColor: String? = nil
    var customCSS: String? = nil
    var singleColumnMode: Bool = true
    var scrollingMode: Bool = false
    var enableMarginClickNavigation: Bool = true
    var userHighlightMode: String = "underline"
    var readaloudHighlightMode: String = "underline"
    var lockViewToAudio: Bool = true

    nonisolated init() {}

    private struct Update: Decodable {
        var fontSize: Double?
        var fontFamily: String?
        var lineSpacing: Double?
        var marginLeftRight: Double?
        var marginTopBottom: Double?
        var wordSpacing: Double?
        var letterSpacing: Double?
        var textAlignment: String?
        var highlightColor: String?
        var highlightThickness: Double?
        var backgroundColor: String?
        var foregroundColor: String?
        var customCSS: String?
        var singleColumnMode: Bool?
        var scrollingMode: Bool?
        var enableMarginClickNavigation: Bool?
        var userHighlightMode: String?
        var readaloudHighlightMode: String?
        var lockViewToAudio: Bool?
    }

    func apply(json: String) throws {
        let update = try JSONDecoder().decode(Update.self, from: Data(json.utf8))
        if let value = update.fontSize { fontSize = value }
        if let value = update.fontFamily { fontFamily = value }
        if let value = update.lineSpacing { lineSpacing = value }
        if let value = update.marginLeftRight { marginLeftRight = value }
        if let value = update.marginTopBottom { marginTopBottom = value }
        if let value = update.wordSpacing { wordSpacing = value }
        if let value = update.letterSpacing { letterSpacing = value }
        if let value = update.textAlignment { textAlignment = value }
        if let value = update.highlightColor { highlightColor = value }
        if let value = update.highlightThickness { highlightThickness = value }
        if let value = update.backgroundColor { backgroundColor = value }
        if let value = update.foregroundColor { foregroundColor = value }
        if let value = update.customCSS { customCSS = value }
        if let value = update.singleColumnMode { singleColumnMode = value }
        if let value = update.scrollingMode { scrollingMode = value }
        if let value = update.enableMarginClickNavigation { enableMarginClickNavigation = value }
        if let value = update.userHighlightMode { userHighlightMode = value }
        if let value = update.readaloudHighlightMode { readaloudHighlightMode = value }
        if let value = update.lockViewToAudio { lockViewToAudio = value }
    }
}

@SilveranUIActor
final class AndroidReaderSession {
    static let shared = AndroidReaderSession()

    private let settings = AndroidReaderSettings()
    private var session: ReadingSession?
    private var bridge: ReaderCommsBridge?
    private var evaluator: AndroidJSEvaluator?
    private var router: ReaderMessageRouter?
    private var styleManager: ReaderStyleManager?
    private var statePublisher: Task<Void, Never>?
    private var lastStatePayload: String?
    private var isDarkMode = false
    private var overlayToggleCount = 0
    private var keepScreenOn = false

    nonisolated private init() {}

    private struct OpenResult: Encodable {
        let readerPath: String
        let originalPath: String
        let hasAudioNarration: Bool
        let title: String
    }

    func open(bookID: BookID, mode: String) async throws -> String {
        await close()

        let category: LocalMediaCategory = mode == "synced" ? .synced : .ebook
        let snapshot = await BookServiceActor.shared.librarySnapshot(policy: .cachedOnly)
        guard let metadata = snapshot.books.first(where: { $0.id == bookID }) else {
            throw AndroidBridgeError.bookNotFound(bookID.uuid)
        }
        let localMedia = await BookServiceActor.shared.resolveLocalMedia(
            for: bookID,
            category: category,
        )

        let evaluator = AndroidJSEvaluator()
        let bridge = ReaderCommsBridge(js: evaluator)
        let router = ReaderMessageRouter(bridge: bridge)
        router.onConsoleLog = { level, message in
            let prefix = level == "error" ? "JS ERROR: " : level == "warn" ? "JS WARN: " : "JS: "
            debugLog("[AndroidReaderSession] \(prefix)\(message)")
        }

        let session = ReadingSessionStore.shared.obtain(
            metadata: metadata,
            category: category,
            localMediaPath: localMedia?.url,
            settings: settings,
        )

        self.evaluator = evaluator
        self.bridge = bridge
        self.router = router
        self.session = session
        overlayToggleCount = 0
        keepScreenOn = false
        lastStatePayload = nil

        let styleManager = ReaderStyleManager(settingsVM: settings, bridge: bridge)
        self.styleManager = styleManager

        session.configureMediaOverlayManager = { [weak self] manager in
            manager.setWakeLock = { on in
                Task { @SilveranUIActor in
                    self?.keepScreenOn = on
                }
            }
        }
        session.onReadaloudAvailabilityChanged = { [weak styleManager] available in
            styleManager?.setReadaloudModeAvailable(available)
        }
        session.onViewStructureReady = { [weak self] in
            guard let self else { return }
            self.styleManager?.sendInitialStyles(isDarkMode: self.isDarkMode)
        }

        session.prepare()
        session.attachBridge(bridge, isRecovery: false)
        bridge.onOverlayToggled = { [weak self] in
            self?.overlayToggleCount += 1
        }

        await session.awaitPreparation()
        if let error = session.lastPrepareError {
            await close()
            throw error
        }
        guard let readerPath = session.extractedEbookPath else {
            await close()
            throw AndroidBridgeError.readerPrepareFailed(bookID.uuid)
        }

        startStatePublisher()

        return try encodeReaderJSON(
            OpenResult(
                readerPath: readerPath.path,
                originalPath: localMedia?.url.path ?? "",
                hasAudioNarration: session.hasAudioNarration,
                title: metadata.title,
            )
        )
    }

    func close() async {
        statePublisher?.cancel()
        statePublisher = nil
        styleManager = nil
        router = nil
        bridge = nil

        let closingSession = session
        session = nil
        if let closingSession {
            await closingSession.close(.endSession)
        }

        evaluator?.close()
        evaluator = nil
        lastStatePayload = nil
    }

    func handleMessage(name: String, body: String) {
        guard let router else {
            debugLog("[AndroidReaderSession] Dropping JS message '\(name)' - no reader open")
            return
        }
        let parsed =
            (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]))
            ?? [String: Any]()
        if !router.route(name: name, body: parsed) {
            debugLog("[AndroidReaderSession] Unhandled JS message: \(name)")
        }
    }

    func completeJSRequest(requestID: String, result: String, error: String) {
        evaluator?.complete(requestID: requestID, result: result, error: error)
    }

    func control(command: String, value: Double, text: String) async throws {
        guard let session else {
            throw AndroidBridgeError.readerNotOpen
        }

        switch command {
            case "goLeft":
                session.progressManager?.handleUserNavLeft()
            case "goRight":
                session.progressManager?.handleUserNavRight()
            case "selectChapter":
                if text.isEmpty {
                    session.progressManager?.handleUserChapterSelected(Int(value))
                } else {
                    session.progressManager?.handleUserChapterSelectedWithHref(
                        Int(value),
                        href: text,
                    )
                }
            case "seekToFraction":
                session.progressManager?.handleUserProgressSeek(value)
            case "togglePlayPause":
                await session.progressManager?.togglePlaying()
            case "nextSentence":
                session.mediaOverlayManager?.nextSentence()
            case "prevSentence":
                session.mediaOverlayManager?.prevSentence()
            case "setRate":
                session.mediaOverlayManager?.setPlaybackRate(value)
            case "setVolume":
                session.mediaOverlayManager?.setVolume(value)
            case "updateReaderSettings":
                try settings.apply(json: text)
            case "setDarkMode":
                isDarkMode = value != 0
                styleManager?.handleDarkModeChange(isDarkMode)
            case "sceneActive":
                await session.handleSceneBecameActive()
            case "sceneBackground":
                await session.handleSceneEnteredBackground()
            default:
                throw AndroidBridgeError.invalidReaderCommand(command)
        }
    }

    private struct ReaderState: Encodable {
        struct Toc: Encodable {
            let label: String
            let href: String
            let level: Int
            let sectionIndex: Int
        }

        let title: String
        let author: String
        let hasAudioNarration: Bool
        let toc: [Toc]
        let selectedChapterId: Int?
        let bookFraction: Double?
        let chapterCurrentPage: Int?
        let chapterTotalPages: Int?
        let isPlaying: Bool
        let playbackRate: Double
        let overlayToggleCount: Int
        let keepScreenOn: Bool
    }

    // The reader state lives across several @Observable objects whose
    // instances are replaced mid-session (EPM/MOM generations), so poll and
    // dedup instead of chaining withObservationTracking registrations.
    private func startStatePublisher() {
        statePublisher?.cancel()
        statePublisher = Task { @SilveranUIActor [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                self.publishState(session)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func publishState(_ session: ReadingSession) {
        let progressManager = session.progressManager
        let overlayManager = session.mediaOverlayManager
        let state = ReaderState(
            title: session.metadata.title,
            author: session.metadata.authors?.first?.name ?? "",
            hasAudioNarration: session.hasAudioNarration,
            toc: session.tocEntries.map {
                ReaderState.Toc(
                    label: $0.label,
                    href: $0.href,
                    level: $0.level,
                    sectionIndex: $0.sectionIndex,
                )
            },
            selectedChapterId: progressManager?.uiSelectedChapterId,
            bookFraction: progressManager?.bookFraction,
            chapterCurrentPage: progressManager?.chapterCurrentPage,
            chapterTotalPages: progressManager?.chapterTotalPages,
            isPlaying: overlayManager?.isPlaying ?? false,
            playbackRate: overlayManager?.playbackRate ?? 1.0,
            overlayToggleCount: overlayToggleCount,
            keepScreenOn: keepScreenOn,
        )

        guard let payload = try? encodeReaderJSON(state), payload != lastStatePayload else {
            return
        }
        lastStatePayload = payload
        notifyAndroidReaderStateDidChange(payload)
    }
}

private func encodeReaderJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
