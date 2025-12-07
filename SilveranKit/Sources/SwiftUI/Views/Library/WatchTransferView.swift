import Foundation
import SwiftUI

#if os(iOS)

struct WatchTransferView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var showBookSearch = false
    @State private var pendingTransfers: [WatchTransferItem] = []
    @State private var watchBooks: [WatchBookInfo] = []
    @State private var isWatchReachable = false
    @State private var observerId: UUID?

    var body: some View {
        List {
            watchStatusSection

            if !pendingTransfers.isEmpty {
                transferringSection
            }

            if !watchBooks.isEmpty {
                onWatchSection
            }

            if watchBooks.isEmpty && pendingTransfers.isEmpty {
                emptyStateSection
            }
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showBookSearch = true
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showBookSearch) {
            WatchBookSearchSheet(onSelect: handleBookSelected, watchBooks: watchBooks)
        }
        .task {
            await setupObserver()
            await refreshState()
        }
        .onDisappear {
            if let id = observerId {
                Task {
                    await AppleWatchActor.shared.removeObserver(id)
                }
            }
        }
    }

    private var watchStatusSection: some View {
        Section {
            HStack {
                if !pendingTransfers.isEmpty && !isWatchReachable {
                    Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                        .foregroundStyle(.orange)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Transferring in Background")
                            .font(.headline)
                        Text("Files transfer when watch wakes or is on charger")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if isWatchReachable {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Watch Connected")
                            .font(.headline)
                        Text("Ready to transfer books")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "applewatch.slash")
                        .foregroundStyle(.secondary)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Watch Not Reachable")
                            .font(.headline)
                        Text("Open app on watch to connect")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var transferringSection: some View {
        Section("Transferring") {
            ForEach(pendingTransfers) { item in
                TransferItemRow(item: item, onCancel: {
                    Task {
                        await AppleWatchActor.shared.cancelTransfer(transferId: item.id)
                    }
                })
            }
        }
    }

    private var onWatchSection: some View {
        Section("On Apple Watch") {
            ForEach(watchBooks) { book in
                WatchBookRow(book: book, onDelete: {
                    Task {
                        await AppleWatchActor.shared.deleteBookFromWatch(bookUUID: book.id, category: book.category)
                    }
                })
            }
        }
    }

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: isWatchReachable ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text(isWatchReachable ? "No Books on Watch" : "Watch Not Connected")
                    .font(.headline)

                Text(isWatchReachable
                     ? "Tap + to search your library and send a book to your Apple Watch."
                     : "Open the Silveran Reader app on your Apple Watch to establish a connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func setupObserver() async {
        let id = await AppleWatchActor.shared.addObserver { event in
            handleEvent(event)
        }
        observerId = id
    }

    @MainActor
    private func handleEvent(_ event: WatchTransferEvent) {
        switch event {
        case .stateChanged:
            Task { await refreshState() }
        case .transfersUpdated(let items):
            pendingTransfers = items
        case .watchBooksUpdated(let books):
            watchBooks = books
        case .watchReachabilityChanged(let reachable):
            isWatchReachable = reachable
        }
    }

    private func refreshState() async {
        let pending = await AppleWatchActor.shared.getPendingTransfers()
        let books = await AppleWatchActor.shared.getWatchBooks()
        let reachable = await AppleWatchActor.shared.isWatchReachable()

        await MainActor.run {
            pendingTransfers = pending
            watchBooks = books
            isWatchReachable = reachable
        }
    }

    private func handleBookSelected(_ book: BookMetadata, _ category: LocalMediaCategory) {
        showBookSearch = false

        guard let url = mediaViewModel.localMediaPath(for: book.uuid, category: category) else {
            debugLog("[WatchTransferView] No file for category \(category): \(book.uuid)")
            return
        }

        Task {
            do {
                try await AppleWatchActor.shared.queueTransfer(
                    book: book,
                    category: category,
                    sourceURL: url
                )
            } catch {
                debugLog("[WatchTransferView] Failed to queue transfer: \(error)")
            }
        }
    }
}

struct TransferItemRow: View {
    let item: WatchTransferItem
    let onCancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: categoryIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.bookTitle)
                        .font(.headline)
                        .lineLimit(1)
                }

                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .transferring = item.state, item.totalBytes > 0 {
                        Text("\(formatBytes(item.transferredBytes)) / \(formatBytes(item.totalBytes))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if case .transferring(let progress) = item.state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else if case .queued = item.state {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            Spacer()

            if canCancel {
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var categoryIcon: String {
        switch item.category {
        case .ebook:
            return "book.closed"
        case .synced:
            return "waveform"
        case .audio:
            return "headphones"
        }
    }

    private var statusText: String {
        switch item.state {
        case .queued:
            return "Preparing..."
        case .transferring(let progress):
            return "Transferring \(String(format: "%.0f", progress * 100))%"
        case .completed:
            return "Completed"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var canCancel: Bool {
        switch item.state {
        case .queued, .transferring:
            return true
        case .completed, .failed:
            return false
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct WatchBookRow: View {
    let book: WatchBookInfo
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: categoryIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                if !book.authorDisplay.isEmpty {
                    Text(book.authorDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(formatBytes(book.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var categoryIcon: String {
        switch book.category {
        case .ebook:
            return "book.closed"
        case .synced:
            return "waveform"
        case .audio:
            return "headphones"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct WatchBookSearchSheet: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showUnsupportedAlert = false
    @State private var unsupportedCategory: LocalMediaCategory?

    let onSelect: (BookMetadata, LocalMediaCategory) -> Void
    let watchBooks: [WatchBookInfo]

    private var downloadedBooks: [BookMetadata] {
        mediaViewModel.library.bookMetaData.filter { book in
            mediaViewModel.isCategoryDownloaded(.ebook, for: book) ||
            mediaViewModel.isCategoryDownloaded(.synced, for: book) ||
            mediaViewModel.isCategoryDownloaded(.audio, for: book)
        }
    }

    private var filteredBooks: [BookMetadata] {
        if searchText.isEmpty {
            return downloadedBooks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return downloadedBooks.filter {
            $0.title.localizedCaseInsensitiveCompare(searchText) == .orderedSame ||
            $0.title.localizedStandardContains(searchText)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredBooks.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Downloaded Books" : "No Results",
                        systemImage: searchText.isEmpty ? "arrow.down.circle" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Download ebooks first to send them to your watch." : "No books match your search.")
                    )
                } else {
                    ForEach(filteredBooks) { book in
                        BookSearchRow(
                            book: book,
                            hasEbook: mediaViewModel.isCategoryDownloaded(.ebook, for: book),
                            hasSynced: mediaViewModel.isCategoryDownloaded(.synced, for: book),
                            hasAudio: mediaViewModel.isCategoryDownloaded(.audio, for: book),
                            ebookOnWatch: isOnWatch(book.uuid, category: .ebook),
                            syncedOnWatch: isOnWatch(book.uuid, category: .synced),
                            audioOnWatch: isOnWatch(book.uuid, category: .audio)
                        ) { category in
                            if category == .synced {
                                onSelect(book, category)
                            } else {
                                unsupportedCategory = category
                                showUnsupportedAlert = true
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search downloaded books")
            .navigationTitle("Send to Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Not Supported", isPresented: $showUnsupportedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if unsupportedCategory == .ebook {
                    Text("Ebook playback on Apple Watch is not yet supported. Only readalong books can be transferred.")
                } else {
                    Text("Audiobook playback on Apple Watch is not yet supported. Only readalong books can be transferred.")
                }
            }
        }
    }

    private func isOnWatch(_ bookUUID: String, category: LocalMediaCategory) -> Bool {
        watchBooks.contains { $0.id == bookUUID && $0.category == category }
    }
}

struct BookSearchRow: View {
    let book: BookMetadata
    let hasEbook: Bool
    let hasSynced: Bool
    let hasAudio: Bool
    let ebookOnWatch: Bool
    let syncedOnWatch: Bool
    let audioOnWatch: Bool
    let onSelect: (LocalMediaCategory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let authors = book.authors, !authors.isEmpty {
                        Text(authors.compactMap { $0.name }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                if hasEbook {
                    Button {
                        onSelect(.ebook)
                    } label: {
                        Label(ebookOnWatch ? "On Watch" : "Ebook", systemImage: ebookOnWatch ? "checkmark" : "book")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ebookOnWatch)
                }

                if hasSynced {
                    Button {
                        onSelect(.synced)
                    } label: {
                        Label(syncedOnWatch ? "On Watch" : "Readalong", systemImage: syncedOnWatch ? "checkmark" : "waveform")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(syncedOnWatch)
                }

                if hasAudio {
                    Button {
                        onSelect(.audio)
                    } label: {
                        Label(audioOnWatch ? "On Watch" : "Audiobook", systemImage: audioOnWatch ? "checkmark" : "headphones")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(audioOnWatch)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#endif
