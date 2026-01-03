import SwiftUI

struct NarratorView: View {
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
    @State private var selectedNarrator: String? = nil
    private let narratorListWidth: CGFloat = 220
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

    private var narratorGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByNarrator(for: mediaKind)
    }

    private var filteredNarratorGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        filterNarrators(narratorGroups)
    }

    var body: some View {
        #if os(macOS)
        macOSSplitView
        #else
        iOSNarratorList
        #endif
    }

    private func filterNarrators(_ groups: [(narrator: BookCreator?, books: [BookMetadata])]) -> [(
        narrator: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }

        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let narratorNameMatches = group.narrator?.name?.lowercased().contains(searchLower) ?? false

            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.narrators?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }

            if narratorNameMatches {
                return (narrator: group.narrator, books: group.books)
            }

            guard !filteredBooks.isEmpty else { return nil }
            return (narrator: group.narrator, books: filteredBooks)
        }
    }
}

// MARK: - Shared Narrator Row

struct NarratorRowContent: View {
    let narratorName: String
    let bookCount: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: "mic.fill")
                #if os(iOS)
                .font(.body)
                #else
                .font(.system(size: 14))
                #endif
                .foregroundStyle(.secondary)
                .frame(width: 28)

            Text(narratorName)
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
extension NarratorView {
    @ViewBuilder
    fileprivate var iOSNarratorList: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredNarratorGroups, id: \.narrator?.name) { group in
                        let narratorName = group.narrator?.name ?? "Unknown Narrator"
                        NavigationLink(value: narratorName) {
                            NarratorRowContent(
                                narratorName: narratorName,
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
            .navigationTitle("Narrators")
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
            .navigationDestination(for: String.self) { narratorName in
                iOSNarratorBooksView(narratorName: narratorName)
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
    private func iOSNarratorBooksView(narratorName: String) -> some View {
        MediaGridView(
            title: narratorName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: nil,
            authorFilter: nil,
            narratorFilter: narratorName,
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
        .navigationTitle(narratorName)
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
extension NarratorView {
    @ViewBuilder
    fileprivate var macOSSplitView: some View {
        HStack(spacing: 0) {
            macOSNarratorListSidebar

            Divider()

            macOSBooksContentArea
        }
    }

    @ViewBuilder
    private var macOSNarratorListSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Narrators")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredNarratorGroups, id: \.narrator?.name) { group in
                        let narratorName = group.narrator?.name ?? "Unknown Narrator"
                        Button {
                            selectedNarrator = narratorName
                        } label: {
                            NarratorRowContent(
                                narratorName: narratorName,
                                bookCount: group.books.count,
                                isSelected: selectedNarrator == narratorName
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
        .frame(width: narratorListWidth)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var macOSBooksContentArea: some View {
        if let narratorName = selectedNarrator {
            MediaGridView(
                title: narratorName,
                searchText: searchText,
                mediaKind: mediaKind,
                tagFilter: nil,
                seriesFilter: nil,
                authorFilter: nil,
                narratorFilter: narratorName,
                statusFilter: nil,
                defaultSort: "title",
                preferredTileWidth: 120,
                minimumTileWidth: 50,
                initialNarrationFilterOption: .both,
                scrollPosition: nil
            )
            .id(narratorName)
        } else {
            VStack {
                Spacer()
                Text("Select a narrator")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
