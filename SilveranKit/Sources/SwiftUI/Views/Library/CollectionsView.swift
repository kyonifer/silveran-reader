import SwiftUI

struct CollectionsView: View {
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
    @State private var settingsViewModel = SettingsViewModel()
    @State private var activeInfoItem: BookMetadata? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var navigationPath = NavigationPath()

    private let sidebarWidth: CGFloat = 340
    private let sidebarSpacing: CGFloat = 1
    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

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
            collectionsListView
                #if os(iOS)
            .navigationTitle("Collections")
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
                .navigationDestination(for: String.self) { collectionIdentifier in
                    collectionDetailView(for: collectionIdentifier)
                        #if os(iOS)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: showOfflineSheet ?? .constant(false)
                    )
                        #endif
                }
                #if os(iOS)
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: mediaKind)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: showOfflineSheet ?? .constant(false)
                )
            }
            .navigationDestination(for: PlayerBookData.self) { bookData in
                playerView(for: bookData)
            }
            #endif
        }
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

    private var collectionsListView: some View {
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

                        collectionsContent(contentWidth: contentWidth)
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
            Text("Books by Collection")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Spacer()
        }
    }

    @ViewBuilder
    private func collectionsContent(contentWidth: CGFloat) -> some View {
        let collectionGroups = mediaViewModel.booksByCollection(for: mediaKind)
        let filteredGroups = filterCollections(collectionGroups)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                collectionSection(
                    collection: group.collection,
                    books: group.books,
                    contentWidth: contentWidth
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No collections found")
                .font(.title)
                .foregroundStyle(.secondary)
            #if os(iOS)
            Text(
                "Books in collections will appear here. Create collections on Storyteller to organize your library."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            #else
            Text(
                "Books in collections will appear here. Create collections on Storyteller to organize your library."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            #endif
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }

    private func filterCollections(
        _ groups: [(collection: BookCollectionSummary?, books: [BookMetadata])]
    ) -> [(
        collection: BookCollectionSummary?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }

        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let collectionNameMatches =
                group.collection?.name.lowercased().contains(searchLower) ?? false

            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }

            if collectionNameMatches {
                return (collection: group.collection, books: group.books)
            }

            guard !filteredBooks.isEmpty else { return nil }
            return (collection: group.collection, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func collectionSection(
        collection: BookCollectionSummary?,
        books: [BookMetadata],
        contentWidth: CGFloat
    )
        -> some View
    {
        let displayBooks = Array(books.prefix(30))
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: mediaKind,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                onSelect: { book in
                    if let collectionId = collection?.uuid ?? collection?.name {
                        navigateToCollection(collectionId)
                    }
                },
                onInfo: { book in
                    activeInfoItem = book
                    isSidebarVisible = true
                }
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                Button {
                    if let collectionId = collection?.uuid ?? collection?.name {
                        navigateToCollection(collectionId)
                    }
                } label: {
                    Text(collection?.name ?? "Unknown Collection")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(collection == nil)
                .frame(maxWidth: .infinity, alignment: .center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func navigateToCollection(_ collectionIdentifier: String) {
        navigationPath.append(collectionIdentifier)
    }

    @ViewBuilder
    private func collectionDetailView(for collectionIdentifier: String) -> some View {
        let collectionName = findCollectionName(for: collectionIdentifier)
        #if os(iOS)
        MediaGridView(
            title: collectionName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: nil,
            collectionFilter: collectionIdentifier,
            statusFilter: nil,
            defaultSort: "titleAZ",
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(collectionName)
        #else
        MediaGridView(
            title: collectionName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: nil,
            collectionFilter: collectionIdentifier,
            statusFilter: nil,
            defaultSort: "titleAZ",
            preferredTileWidth: 120,
            minimumTileWidth: 50,
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(collectionName)
        #endif
    }

    private func findCollectionName(for identifier: String) -> String {
        let groups = mediaViewModel.booksByCollection(for: mediaKind)
        for group in groups {
            if let collection = group.collection {
                if collection.uuid == identifier || collection.name == identifier {
                    return collection.name
                }
            }
        }
        return identifier
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
