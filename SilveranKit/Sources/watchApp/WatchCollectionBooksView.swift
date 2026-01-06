#if os(watchOS)
import SilveranKitCommon
import SwiftUI

struct WatchCollectionBooksView: View {
    let collection: BookCollectionSummary

    @Environment(WatchViewModel.self) private var viewModel

    @State private var books: [BookMetadata] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var downloadingBook: BookMetadata?

    private func isBookDownloaded(_ uuid: String) -> Bool {
        viewModel.books.contains { $0.uuid == uuid }
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if books.isEmpty {
                emptyView
            } else {
                bookList
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadBooks()
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
    }

    private var loadingView: some View {
        ScrollView {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task {
                        await loadBooks()
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No books in this collection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
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

        guard let library = await StorytellerActor.shared.fetchLibraryInformation() else {
            isLoading = false
            errorMessage = "Cannot connect to server"
            return
        }

        let collectionKey = collection.uuid ?? collection.name

        let filtered = library.filter { book in
            guard book.hasAvailableReadaloud else { return false }
            guard let bookCollections = book.collections else { return false }
            return bookCollections.contains { c in
                (c.uuid ?? c.name) == collectionKey
            }
        }

        let sorted = filtered.sorted { a, b in
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        books = sorted
        isLoading = false
    }
}

#endif
