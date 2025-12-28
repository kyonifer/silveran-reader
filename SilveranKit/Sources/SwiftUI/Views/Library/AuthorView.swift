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
    @State private var activeInfoItem: BookMetadata? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var navigationPath = NavigationPath()

    private let sidebarWidth: CGFloat = 340
    private let sidebarSpacing: CGFloat = 1
    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32
    private let tileWidth: CGFloat = 150
    private let tileHeight: CGFloat = 220

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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            authorListContent
        }
    }

    @ViewBuilder
    private var authorListContent: some View {
        authorListView
            #if os(iOS)
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
            #endif
            .navigationDestination(for: String.self) { authorName in
                authorDetailView(for: authorName)
            }
            #if os(iOS)
        .navigationDestination(for: BookMetadata.self) { item in
            iOSBookDetailView(item: item, mediaKind: mediaKind)
        }
        .navigationDestination(for: PlayerBookData.self) { bookData in
            playerView(for: bookData)
        }
        #endif
        #if os(macOS)
        .onKeyPress(.escape) {
            if isSidebarVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarVisible = false
                }
                return .handled
            }
            return .ignored
        }
        #endif
    }

    private var authorListView: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width
            let contentWidth =
                isSidebarVisible
                ? max(containerWidth - sidebarWidth - sidebarSpacing, 0)
                : containerWidth

            HStack(spacing: sidebarSpacing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        headerView

                        authorContent(contentWidth: contentWidth)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
                .modifier(SoftScrollEdgeModifier())
                .frame(width: contentWidth)

                if isSidebarVisible, let item = activeInfoItem {
                    MediaGridInfoSidebar(
                        item: item,
                        mediaKind: mediaKind,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSidebarVisible = false
                            }
                        },
                        onReadNow: {},
                        onRename: {},
                        onDelete: {}
                    )
                    .frame(width: sidebarWidth)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isSidebarVisible)
        }
    }

    private var headerView: some View {
        HStack {
            Text("Books by Author")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Spacer()
        }
    }

    @ViewBuilder
    private func authorContent(contentWidth: CGFloat) -> some View {
        let authorGroups = mediaViewModel.booksByAuthor(for: mediaKind)
        let filteredGroups = filterAuthors(authorGroups)

        let columns = calculateColumns(contentWidth: contentWidth)

        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                authorCard(
                    author: group.author,
                    books: group.books
                )
            }
        }
    }

    private func calculateColumns(contentWidth: CGFloat) -> [GridItem] {
        let availableWidth = contentWidth - (horizontalPadding * 2)
        let columnCount = max(1, Int(availableWidth / tileWidth))
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
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

    @ViewBuilder
    private func authorCard(author: BookCreator?, books: [BookMetadata]) -> some View {
        VStack(spacing: 12) {
            Button {
                if let authorName = author?.name {
                    navigateToAuthor(authorName)
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: tileWidth, height: tileWidth)

                    Image(systemName: "person.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .disabled(author == nil)

            VStack(alignment: .center, spacing: 6) {
                Button {
                    if let authorName = author?.name {
                        navigateToAuthor(authorName)
                    }
                } label: {
                    Text(author?.name ?? "Unknown Author")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .disabled(author == nil)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: tileWidth)
        }
    }

    private func navigateToAuthor(_ authorName: String) {
        navigationPath.append(authorName)
    }

    @ViewBuilder
    private func authorDetailView(for authorName: String) -> some View {
        #if os(iOS)
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
        #else
        MediaGridView(
            title: authorName,
            searchText: "",
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
        .navigationTitle(authorName)
        #endif
    }

    @ViewBuilder
    private func playerView(for bookData: PlayerBookData) -> some View {
        switch bookData.category {
            case .audio:
                AudiobookPlayerView(bookData: bookData)
                    #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                    #endif
            case .ebook, .synced:
                EbookPlayerView(bookData: bookData)
                    #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                    #endif
        }
    }
}
