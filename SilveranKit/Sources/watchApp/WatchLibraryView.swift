import SilveranKitCommon
import SwiftUI

struct WatchLibraryView: View {
    @Environment(WatchViewModel.self) private var viewModel
    @State private var showSyncView = false

    var body: some View {
        Group {
            if viewModel.books.isEmpty {
                emptyState
            } else {
                bookList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSyncView = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                }
            }
        }
        .sheet(isPresented: $showSyncView) {
            WatchCloudKitSyncView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("No Books")
                .font(.headline)

            Text("Send books from the\nMore menu of the iPhone app")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var bookList: some View {
        List {
            ForEach(viewModel.books) { book in
                if book.category == "synced" {
                    NavigationLink {
                        WatchPlayerView(book: book)
                    } label: {
                        BookRow(book: book)
                    }
                } else {
                    NavigationLink {
                        BookDetailView(book: book)
                    } label: {
                        BookRow(book: book)
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    viewModel.deleteBook(viewModel.books[index])
                }
            }
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

                Text("EPUB reading not yet supported on Apple Watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
}
