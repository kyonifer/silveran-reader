#if os(watchOS)
import SilveranKitCommon
import SwiftUI

struct WatchCurrentlyReadingView: View {
    @Environment(WatchViewModel.self) private var viewModel

    @State private var books: [BookMetadata] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsServerSetup = false
    @State private var showSettingsView = false
    @State private var downloadingBook: BookMetadata?

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if needsServerSetup {
                serverSetupView
            } else if let error = errorMessage {
                errorView(error)
            } else if books.isEmpty {
                emptyView
            } else {
                bookList
            }
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadBooks()
        }
        .sheet(isPresented: $showSettingsView) {
            WatchSettingsView()
        }
        .fullScreenCover(item: $downloadingBook) { book in
            WatchDownloadProgressView(
                book: book,
                onCancel: {
                    Task {
                        await WatchDownloadManager.shared.cancelDownload(bookId: book.uuid)
                    }
                    downloadingBook = nil
                },
                onComplete: {
                    downloadingBook = nil
                    viewModel.loadBooks()
                }
            )
        }
        .onChange(of: showSettingsView) { _, isShowing in
            if !isShowing {
                Task {
                    await loadBooks()
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverSetupView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Server Not Configured")
                .font(.caption)
            Text("Set up your Storyteller server to download books")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showSettingsView = true
            } label: {
                Text("Server Settings")
                    .font(.caption2)
            }
            .controlSize(.small)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        await loadBooks()
                    }
                }
                .controlSize(.small)
                Button {
                    showSettingsView = true
                } label: {
                    Text("Settings")
                }
                .controlSize(.small)
                .tint(.secondary)
            }
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No books currently reading")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Start reading a book on your phone to see it here")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var bookList: some View {
        List {
            ForEach(books) { book in
                Button {
                    if !isBookDownloaded(book.uuid) {
                        downloadingBook = book
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.caption)
                                .lineLimit(2)

                            if let author = book.authors?.first?.name {
                                Text(author)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if isBookDownloaded(book.uuid) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadBooks() async {
        isLoading = true
        errorMessage = nil
        needsServerSetup = false

        let isConfigured = await StorytellerActor.shared.isConfigured
        if !isConfigured {
            isLoading = false
            needsServerSetup = true
            return
        }

        let status = await StorytellerActor.shared.connectionStatus
        if status != .connected {
            guard let library = await StorytellerActor.shared.fetchLibraryInformation() else {
                isLoading = false
                errorMessage = "Cannot connect to server"
                return
            }
            books = filterAndSortBooks(library)
            isLoading = false
            return
        }

        guard let library = await StorytellerActor.shared.fetchLibraryInformation() else {
            isLoading = false
            errorMessage = "Failed to load library"
            return
        }

        books = filterAndSortBooks(library)
        isLoading = false
    }

    private func filterAndSortBooks(_ library: [BookMetadata]) -> [BookMetadata] {
        let reading = library.filter { book in
            book.status?.name == "Reading" && book.hasAvailableReadaloud
        }

        let sorted = reading.sorted { a, b in
            let tsA = a.position?.timestamp ?? 0
            let tsB = b.position?.timestamp ?? 0
            return tsA > tsB
        }

        return Array(sorted.prefix(20))
    }

    private func isBookDownloaded(_ uuid: String) -> Bool {
        let watchBooks = viewModel.books
        return watchBooks.contains { $0.uuid == uuid }
    }
}

#Preview {
    WatchCurrentlyReadingView()
}
#endif
