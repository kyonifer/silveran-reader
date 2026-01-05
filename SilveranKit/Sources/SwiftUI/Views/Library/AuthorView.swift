import SwiftUI

struct AuthorView: View {
    let mediaKind: MediaKind
    #if os(iOS)
    @Binding var searchText: String
    #else
    let searchText: String
    #endif
    @Binding var sidebarSections: [SidebarSectionDescription]
    @Binding var selectedSidebarItem: SidebarItemDescription?
    @Binding var showSettings: Bool
    #if os(iOS)
    var showOfflineSheet: Binding<Bool>?
    #endif
    @Environment(MediaViewModel.self) private var mediaViewModel

    #if os(macOS)
    @State private var selectedAuthor: String? = nil
    @State private var activeInfoItem: BookMetadata? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var authorListWidth: CGFloat = 220
    private let infoSidebarWidth: CGFloat = 340
    #endif

    #if os(iOS)
    private var hasConnectionError: Bool {
        if mediaViewModel.lastNetworkOpSucceeded == false { return true }
        if case .error = mediaViewModel.connectionStatus { return true }
        return false
    }

    private var connectionErrorIcon: String {
        if case .error = mediaViewModel.connectionStatus {
            return "exclamationmark.triangle"
        }
        return "wifi.slash"
    }
    #endif

    private var authorGroups: [(author: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByAuthor(for: mediaKind)
    }

    private var filteredAuthorGroups: [(author: BookCreator?, books: [BookMetadata])] {
        filterAuthors(authorGroups)
    }

    var body: some View {
        #if os(macOS)
        macOSSplitView
            .onKeyPress(.escape) {
                if isSidebarVisible {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible = false
                    }
                    return .handled
                }
                return .ignored
            }
        #else
        iOSAuthorList
        #endif
    }

    private func filterAuthors(_ groups: [(author: BookCreator?, books: [BookMetadata])]) -> [(
        author: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }

        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let authorNameMatches = group.author?.name?.lowercased().contains(searchLower) ?? false

            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
                    || book.series?.contains(where: { $0.name.lowercased().contains(searchLower) })
                        ?? false
            }

            if authorNameMatches {
                return (author: group.author, books: group.books)
            }

            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }
}

// MARK: - Shared Author Row

struct AuthorRowContent: View {
    let authorName: String
    let bookCount: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "person.fill")
                #if os(iOS)
                .font(.body)
                #else
                .font(.system(size: 14))
                #endif
                .foregroundStyle(.secondary)
                .frame(width: 28)

            Text(authorName)
                #if os(iOS)
                .font(.body)
                #else
                .font(.system(size: 14))
                #endif
                .lineLimit(1)

            Spacer()

            Text("\(bookCount)")
                #if os(iOS)
                .font(.subheadline)
                #else
                .font(.system(size: 12))
                #endif
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .padding(.horizontal, 16)
        #if os(iOS)
        .padding(.vertical, 12)
        #else
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        #endif
    }
}

// MARK: - iOS Implementation

#if os(iOS)
extension AuthorView {
    @ViewBuilder
    fileprivate var iOSAuthorList: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredAuthorGroups, id: \.author?.name) { group in
                        let authorName = group.author?.name ?? "Unknown Author"
                        NavigationLink(value: authorName) {
                            AuthorRowContent(
                                authorName: authorName,
                                bookCount: group.books.count,
                                isSelected: false
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 48)
                    }
                }
                .padding(.top, 8)
            }
            .navigationTitle("Authors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if hasConnectionError,
                            let showOfflineSheet
                        {
                            Button {
                                showOfflineSheet.wrappedValue = true
                            } label: {
                                Image(systemName: connectionErrorIcon)
                                    .foregroundStyle(.red)
                            }
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .navigationDestination(for: String.self) { authorName in
                iOSAuthorBooksView(authorName: authorName)
            }
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: mediaKind)
            }
            .navigationDestination(for: PlayerBookData.self) { bookData in
                iOSPlayerView(for: bookData)
            }
        }
    }

    @ViewBuilder
    private func iOSAuthorBooksView(authorName: String) -> some View {
        MediaGridView(
            title: authorName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: nil,
            authorFilter: authorName,
            statusFilter: nil,
            defaultSort: "title",
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(authorName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func iOSPlayerView(for bookData: PlayerBookData) -> some View {
        switch bookData.category {
            case .audio:
                AudiobookPlayerView(bookData: bookData)
                    .navigationBarTitleDisplayMode(.inline)
            case .ebook, .synced:
                EbookPlayerView(bookData: bookData)
                    .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif

// MARK: - macOS Implementation

#if os(macOS)
extension AuthorView {
    @ViewBuilder
    fileprivate var macOSSplitView: some View {
        HStack(spacing: 0) {
            macOSAuthorListSidebar

            ResizableDivider(width: $authorListWidth, minWidth: 150, maxWidth: 400)

            macOSBooksContentArea
        }
    }

    @ViewBuilder
    private var macOSAuthorListSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Authors")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredAuthorGroups, id: \.author?.name) { group in
                        let authorName = group.author?.name ?? "Unknown Author"
                        Button {
                            selectedAuthor = authorName
                        } label: {
                            AuthorRowContent(
                                authorName: authorName,
                                bookCount: group.books.count,
                                isSelected: selectedAuthor == authorName
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .frame(width: authorListWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var macOSBooksContentArea: some View {
        if let authorName = selectedAuthor {
            MediaGridView(
                title: authorName,
                searchText: searchText,
                mediaKind: mediaKind,
                tagFilter: nil,
                seriesFilter: nil,
                authorFilter: authorName,
                statusFilter: nil,
                defaultSort: "title",
                preferredTileWidth: 120,
                minimumTileWidth: 50,
                initialNarrationFilterOption: .both,
                scrollPosition: nil
            )
            .id(authorName)
        } else {
            VStack {
                Spacer()
                Text("Select an author")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
