import SwiftUI

struct TagView: View {
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
    @State private var selectedTag: String? = nil
    private let tagListWidth: CGFloat = 220
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

    private var tagGroups: [(tag: String, books: [BookMetadata])] {
        mediaViewModel.booksByTag(for: mediaKind)
    }

    private var filteredTagGroups: [(tag: String, books: [BookMetadata])] {
        filterTags(tagGroups)
    }

    var body: some View {
        #if os(macOS)
        macOSSplitView
        #else
        iOSTagList
        #endif
    }

    private func filterTags(_ groups: [(tag: String, books: [BookMetadata])]) -> [(
        tag: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }

        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let tagMatches = group.tag.lowercased().contains(searchLower)

            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.tagNames.contains(where: { $0.lowercased().contains(searchLower) })
            }

            if tagMatches {
                return (tag: group.tag, books: group.books)
            }

            guard !filteredBooks.isEmpty else { return nil }
            return (tag: group.tag, books: filteredBooks)
        }
    }
}

// MARK: - Shared Tag Row

struct TagRowContent: View {
    let tagName: String
    let bookCount: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "tag.fill")
                #if os(iOS)
                .font(.body)
                #else
                .font(.system(size: 14))
                #endif
                .foregroundStyle(.secondary)
                .frame(width: 28)

            Text(tagName.capitalized)
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
extension TagView {
    @ViewBuilder
    fileprivate var iOSTagList: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredTagGroups, id: \.tag) { group in
                        NavigationLink(value: group.tag) {
                            TagRowContent(
                                tagName: group.tag,
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
            .navigationTitle("Tags")
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
            .navigationDestination(for: String.self) { tagName in
                iOSTagBooksView(tagName: tagName)
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
    private func iOSTagBooksView(tagName: String) -> some View {
        MediaGridView(
            title: tagName.capitalized,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: tagName,
            seriesFilter: nil,
            authorFilter: nil,
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
        .navigationTitle(tagName.capitalized)
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
extension TagView {
    @ViewBuilder
    fileprivate var macOSSplitView: some View {
        HStack(spacing: 0) {
            macOSTagListSidebar

            Divider()

            macOSBooksContentArea
        }
    }

    @ViewBuilder
    private var macOSTagListSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tags")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredTagGroups, id: \.tag) { group in
                        Button {
                            selectedTag = group.tag
                        } label: {
                            TagRowContent(
                                tagName: group.tag,
                                bookCount: group.books.count,
                                isSelected: selectedTag == group.tag
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
        .frame(width: tagListWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var macOSBooksContentArea: some View {
        if let tagName = selectedTag {
            MediaGridView(
                title: tagName.capitalized,
                searchText: searchText,
                mediaKind: mediaKind,
                tagFilter: tagName,
                seriesFilter: nil,
                authorFilter: nil,
                statusFilter: nil,
                defaultSort: "title",
                preferredTileWidth: 120,
                minimumTileWidth: 50,
                initialNarrationFilterOption: .both,
                scrollPosition: nil
            )
            .id(tagName)
        } else {
            VStack {
                Spacer()
                Text("Select a tag")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
