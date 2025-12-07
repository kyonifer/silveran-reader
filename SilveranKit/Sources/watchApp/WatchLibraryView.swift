import SwiftUI

struct WatchLibraryView: View {
    @Environment(WatchViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.books.isEmpty {
                    emptyState
                } else {
                    bookList
                }
            }
            .navigationTitle("Library")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("No Books")
                .font(.headline)

            Text("Send books from your iPhone")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var bookList: some View {
        List {
            ForEach(viewModel.books) { book in
                NavigationLink(value: book) {
                    BookRow(book: book)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    viewModel.deleteBook(viewModel.books[index])
                }
            }
        }
        .navigationDestination(for: WatchBookEntry.self) { book in
            BookDetailView(book: book)
        }
    }
}

struct BookRow: View {
    let book: WatchBookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: categoryIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
            }

            if !book.authorDisplay.isEmpty {
                Text(book.authorDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var categoryIcon: String {
        switch book.category {
        case "ebook":
            return "book.closed"
        case "synced":
            return "waveform"
        case "audio":
            return "headphones"
        default:
            return "doc"
        }
    }
}

struct BookDetailView: View {
    let book: WatchBookEntry
    @Environment(WatchViewModel.self) private var viewModel
    @State private var showPlayer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(book.title)
                    .font(.headline)

                if !book.authorDisplay.isEmpty {
                    Text(book.authorDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                if book.category == "synced" {
                    NavigationLink(destination: WatchPlayerView(book: book)) {
                        Label("Listen", systemImage: "headphones")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        openBook()
                    } label: {
                        Label("Read", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    viewModel.deleteBook(book)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openBook() {
        // Future: Launch EPUB reader for ebooks
    }
}
