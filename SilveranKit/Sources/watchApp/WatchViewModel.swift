import Foundation
import SwiftUI

@MainActor
@Observable
public final class WatchViewModel {
    var books: [WatchBookEntry] = []
    var receivingTitle: String?
    var receivedChunks: Int = 0
    var totalChunks: Int = 0

    var isReceiving: Bool {
        receivingTitle != nil
    }

    var transferProgress: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(receivedChunks) / Double(totalChunks)
    }

    init() {
        loadBooks()
        setupObservers()
    }

    private func setupObservers() {
        WatchSessionManager.shared.onTransferProgress = { [weak self] title, received, total in
            Task { @MainActor in
                self?.receivingTitle = title
                self?.receivedChunks = received
                self?.totalChunks = total
            }
        }

        WatchSessionManager.shared.onTransferComplete = { [weak self] in
            Task { @MainActor in
                self?.receivingTitle = nil
                self?.receivedChunks = 0
                self?.totalChunks = 0
                self?.loadBooks()
            }
        }

        WatchSessionManager.shared.onBookDeleted = { [weak self] in
            Task { @MainActor in
                self?.loadBooks()
            }
        }
    }

    func loadBooks() {
        books = WatchStorageManager.shared.loadAllBooks()
    }

    func deleteBook(_ book: WatchBookEntry) {
        WatchStorageManager.shared.deleteBook(uuid: book.uuid, category: book.category)
        loadBooks()
    }
}
