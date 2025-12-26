import Foundation
import SilveranKitCommon
import SwiftUI

@MainActor
@Observable
public final class WatchViewModel {
    var books: [BookMetadata] = []
    var receivingTitle: String?
    var receivedChunks: Int = 0
    var totalChunks: Int = 0
    var remotePlaybackState: RemotePlaybackState?
    private var metadataRefreshTask: Task<Void, Never>?

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
        startMetadataRefreshTask()
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

        WatchSessionManager.shared.onPlaybackStateReceived = { [weak self] state in
            Task { @MainActor in
                self?.remotePlaybackState = state
            }
        }

        Task {
            await LocalMediaActor.shared.addObserver { [weak self] in
                Task { @MainActor in
                    self?.loadBooks()
                }
            }
        }
    }

    func requestPlaybackState() {
        WatchSessionManager.shared.requestPlaybackState()
    }

    func sendPlaybackCommand(_ command: RemotePlaybackCommand) {
        WatchSessionManager.shared.sendPlaybackCommand(command)
    }

    func loadBooks() {
        Task {
            let storytellerBooks = await LocalMediaActor.shared.localStorytellerMetadata
            var booksWithFiles: [BookMetadata] = []
            for book in storytellerBooks {
                let path = await LocalMediaActor.shared.mediaFilePath(for: book.uuid, category: .synced)
                if path != nil {
                    booksWithFiles.append(book)
                }
            }
            await MainActor.run {
                self.books = booksWithFiles
            }
        }
    }

    func deleteBook(_ book: BookMetadata, category: LocalMediaCategory) {
        Task {
            try? await LocalMediaActor.shared.deleteMedia(for: book.uuid, category: category)
        }
    }

    private func startMetadataRefreshTask() {
        metadataRefreshTask?.cancel()
        metadataRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let config = await SettingsActor.shared.config
                let refreshInterval = config.sync.metadataRefreshIntervalSeconds

                if config.sync.isMetadataRefreshDisabled {
                    debugLog("[WatchViewModel] Metadata auto-refresh is disabled")
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }

                debugLog("[WatchViewModel] Next metadata refresh in \(Int(refreshInterval))s")
                try? await Task.sleep(for: .seconds(refreshInterval))

                guard !Task.isCancelled else { return }

                let status = await StorytellerActor.shared.connectionStatus
                if status == .connected {
                    debugLog("[WatchViewModel] Periodic metadata refresh")
                    let _ = await StorytellerActor.shared.fetchLibraryInformation()
                    self?.loadBooks()
                } else {
                    debugLog("[WatchViewModel] Skipping refresh - not connected to server")
                }
            }
        }
    }
}
