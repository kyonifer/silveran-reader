import Foundation

@globalActor
public actor BookmarkActor {
    public static let shared = BookmarkActor()

    private var highlightsByBook: [String: [Highlight]] = [:]
    private var loadedBooks: Set<String> = []
    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]

    public init() {}

    public func getHighlights(bookId: String) async -> [Highlight] {
        await ensureLoaded(bookId: bookId)
        return highlightsByBook[bookId] ?? []
    }

    public func getBookmarks(bookId: String) async -> [Highlight] {
        let all = await getHighlights(bookId: bookId)
        return all.filter { $0.isBookmark }
    }

    public func getColoredHighlights(bookId: String) async -> [Highlight] {
        let all = await getHighlights(bookId: bookId)
        return all.filter { !$0.isBookmark }
    }

    public func addHighlight(_ highlight: Highlight) async {
        await ensureLoaded(bookId: highlight.bookId)

        var highlights = highlightsByBook[highlight.bookId] ?? []
        highlights.append(highlight)
        highlights.sort { $0.createdAt > $1.createdAt }
        highlightsByBook[highlight.bookId] = highlights

        await saveToDisk(bookId: highlight.bookId)
        await notifyObservers()

        debugLog(
            "[BookmarkActor] addHighlight: id=\(highlight.id), bookId=\(highlight.bookId), isBookmark=\(highlight.isBookmark)"
        )
    }

    public func deleteHighlight(id: UUID, bookId: String) async {
        await ensureLoaded(bookId: bookId)

        guard var highlights = highlightsByBook[bookId] else { return }

        let before = highlights.count
        highlights.removeAll { $0.id == id }
        highlightsByBook[bookId] = highlights

        if highlights.count != before {
            await saveToDisk(bookId: bookId)
            await notifyObservers()
            debugLog("[BookmarkActor] deleteHighlight: id=\(id), bookId=\(bookId)")
        }
    }

    public func updateHighlight(_ highlight: Highlight) async {
        await ensureLoaded(bookId: highlight.bookId)

        guard var highlights = highlightsByBook[highlight.bookId] else { return }

        if let index = highlights.firstIndex(where: { $0.id == highlight.id }) {
            highlights[index] = highlight
            highlightsByBook[highlight.bookId] = highlights
            await saveToDisk(bookId: highlight.bookId)
            await notifyObservers()
            debugLog(
                "[BookmarkActor] updateHighlight: id=\(highlight.id), bookId=\(highlight.bookId)"
            )
        }
    }

    public func deleteAllHighlights(bookId: String) async {
        highlightsByBook[bookId] = []
        loadedBooks.insert(bookId)

        do {
            try await FilesystemActor.shared.deleteHighlights(bookId: bookId)
            debugLog("[BookmarkActor] deleteAllHighlights: bookId=\(bookId)")
        } catch {
            debugLog("[BookmarkActor] deleteAllHighlights failed: \(error)")
        }

        await notifyObservers()
    }

    @discardableResult
    public func addObserver(_ callback: @escaping @Sendable @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        debugLog("[BookmarkActor] addObserver: id=\(id), total=\(observers.count)")
        return id
    }

    public func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
        debugLog("[BookmarkActor] removeObserver: id=\(id), total=\(observers.count)")
    }

    private func ensureLoaded(bookId: String) async {
        guard !loadedBooks.contains(bookId) else { return }

        do {
            if let highlights = try await FilesystemActor.shared.loadHighlights(bookId: bookId) {
                highlightsByBook[bookId] = highlights
                debugLog("[BookmarkActor] loaded \(highlights.count) highlights for book \(bookId)")
            } else {
                highlightsByBook[bookId] = []
                debugLog("[BookmarkActor] no highlights file for book \(bookId)")
            }
        } catch {
            debugLog("[BookmarkActor] loadHighlights failed for \(bookId): \(error)")
            highlightsByBook[bookId] = []
        }

        loadedBooks.insert(bookId)
    }

    private func saveToDisk(bookId: String) async {
        let highlights = highlightsByBook[bookId] ?? []
        do {
            try await FilesystemActor.shared.saveHighlights(bookId: bookId, highlights: highlights)
            debugLog("[BookmarkActor] saved \(highlights.count) highlights for book \(bookId)")
        } catch {
            debugLog("[BookmarkActor] saveHighlights failed for \(bookId): \(error)")
        }
    }

    private func notifyObservers() async {
        for (_, callback) in observers {
            await callback()
        }
    }
}
