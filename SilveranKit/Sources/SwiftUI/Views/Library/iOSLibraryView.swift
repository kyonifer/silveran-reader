#if os(iOS)
import SwiftUI

public struct iOSLibraryView: View {
    @State private var searchText: String = ""
    @State private var selectedTab: Tab = .home
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    @State private var selectedItem: SidebarItemDescription? = nil
    @State private var moreNavigationPath = NavigationPath()
    @State private var showCarPlayPlayer: Bool = false
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    public init() {}

    private var carPlayBook: BookMetadata? {
        guard let bookId = CarPlayCoordinator.shared.activeBookId else { return nil }
        return mediaViewModel.library.bookMetaData.first { $0.id == bookId }
    }

    enum Tab: String, CaseIterable {
        case home
        case books
        case series
        case more

        var label: String {
            switch self {
                case .home: "Home"
                case .books: "Books"
                case .series: "Series"
                case .more: "More"
            }
        }

        var iconName: String {
            switch self {
                case .home: "house.fill"
                case .books: "books.vertical.fill"
                case .series: "square.stack.fill"
                case .more: "ellipsis.circle.fill"
            }
        }
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem {
                    Label(Tab.home.label, systemImage: Tab.home.iconName)
                }
                .tag(Tab.home)

            booksTab
                .tabItem {
                    Label(Tab.books.label, systemImage: Tab.books.iconName)
                }
                .tag(Tab.books)

            seriesTab
                .tabItem {
                    Label(Tab.series.label, systemImage: Tab.series.iconName)
                }
                .tag(Tab.series)

            moreTab
                .tabItem {
                    Label(Tab.more.label, systemImage: Tab.more.iconName)
                }
                .tag(Tab.more)
        }
        .onChange(of: selectedTab) { _, _ in
            searchText = ""
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showOfflineSheet) {
            OfflineStatusSheet(
                onGoToDownloads: {
                    showOfflineSheet = false
                    selectedTab = .more
                    moreNavigationPath.append(MoreMenuView.MoreDestination.downloaded)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .safeAreaInset(edge: .top) {
            if CarPlayCoordinator.shared.isCarPlayConnected,
               CarPlayCoordinator.shared.isPlaying,
               !CarPlayCoordinator.shared.isPlayerViewActive,
               let book = carPlayBook
            {
                CarPlayNowPlayingBanner(bookTitle: book.title) {
                    showCarPlayPlayer = true
                }
            }
        }
        .fullScreenCover(isPresented: $showCarPlayPlayer) {
            if let book = carPlayBook,
               let category = CarPlayCoordinator.shared.activeCategory,
               let path = mediaViewModel.localMediaPath(for: book.id, category: category)
            {
                let cover = mediaViewModel.coverImage(for: book, variant: .standard)
                NavigationStack {
                    playerView(for: PlayerBookData(
                        metadata: book,
                        localMediaPath: path,
                        category: category,
                        coverArt: cover
                    ))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") {
                                showCarPlayPlayer = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var homeTab: some View {
        HomeView(
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }

    private var booksTab: some View {
        NavigationStack {
            MediaGridView(
                title: "All Books",
                searchText: searchText,
                mediaKind: .ebook,
                tagFilter: nil,
                seriesFilter: nil,
                statusFilter: nil,
                defaultSort: "titleAZ",
                preferredTileWidth: 110,
                minimumTileWidth: 90,
                columnBreakpoints: [
                    MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                ],
                initialNarrationFilterOption: .both
            )
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if mediaViewModel.lastNetworkOpSucceeded == false {
                            Button {
                                showOfflineSheet = true
                            } label: {
                                Image(systemName: "wifi.slash")
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
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: .ebook)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet
                    )
            }
            .navigationDestination(for: PlayerBookData.self) { bookData in
                playerView(for: bookData)
            }
        }
    }

    private var seriesTab: some View {
        SeriesView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }

    private var moreTab: some View {
        NavigationStack(path: $moreNavigationPath) {
            MoreMenuView(
                searchText: $searchText,
                showSettings: $showSettings,
                showOfflineSheet: $showOfflineSheet,
                navigationPath: $moreNavigationPath
            )
        }
    }

    @ViewBuilder
    private func playerView(for bookData: PlayerBookData) -> some View {
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

struct MoreMenuView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Binding var navigationPath: NavigationPath
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var isWatchPaired = false

    enum MoreDestination: Hashable {
        case authors
        case collections
        case downloaded
        case addLocalFile
        case appleWatch
    }

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.authors) {
                    Label("Authors", systemImage: "person.2.fill")
                }
                NavigationLink(value: MoreDestination.collections) {
                    Label("Custom Collections", systemImage: "rectangle.stack")
                }
                NavigationLink(value: MoreDestination.downloaded) {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                }
                NavigationLink(value: MoreDestination.addLocalFile) {
                    Label("Manage Local Files", systemImage: "folder.badge.plus")
                }
                if isWatchPaired {
                    NavigationLink(value: MoreDestination.appleWatch) {
                        Label("Apple Watch", systemImage: "applewatch")
                    }
                }
            }
        }
        .task {
            isWatchPaired = await AppleWatchActor.shared.isWatchPaired()
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if mediaViewModel.lastNetworkOpSucceeded == false {
                        Button {
                            showOfflineSheet = true
                        } label: {
                            Image(systemName: "wifi.slash")
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
        .navigationDestination(for: MoreDestination.self) { destination in
            switch destination {
                case .authors:
                    AuthorsListView(searchText: $searchText)
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet
                        )
                case .collections:
                    CollectionsListView(
                        searchText: $searchText,
                        navigationPath: $navigationPath
                    )
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet
                    )
                case .downloaded:
                    MediaGridView(
                        title: "Downloaded",
                        searchText: searchText,
                        mediaKind: .ebook,
                        tagFilter: nil,
                        seriesFilter: nil,
                        statusFilter: nil,
                        defaultSort: "titleAZ",
                        preferredTileWidth: 110,
                        minimumTileWidth: 90,
                        columnBreakpoints: [
                            MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                        ],
                        initialNarrationFilterOption: .both,
                        initialLocationFilter: .downloaded
                    )
                    .navigationTitle("Downloaded")
                    .navigationBarTitleDisplayMode(.inline)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet
                    )
                case .addLocalFile:
                    ImportLocalFileView()
                        .navigationTitle("Manage Local Files")
                        .navigationBarTitleDisplayMode(.inline)
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet
                        )
                case .appleWatch:
                    WatchTransferView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet
                        )
            }
        }
        .navigationDestination(for: String.self) { authorName in
            MediaGridView(
                title: authorName,
                searchText: "",
                mediaKind: .ebook,
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
                initialNarrationFilterOption: .both
            )
            .navigationTitle(authorName)
            .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        }
        .navigationDestination(for: CollectionNavIdentifier.self) { collection in
            MediaGridView(
                title: collection.name,
                searchText: "",
                mediaKind: .ebook,
                tagFilter: nil,
                seriesFilter: nil,
                collectionFilter: collection.id,
                statusFilter: nil,
                defaultSort: "titleAZ",
                preferredTileWidth: 110,
                minimumTileWidth: 90,
                columnBreakpoints: [
                    MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                ],
                initialNarrationFilterOption: .both
            )
            .navigationTitle(collection.name)
            .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        }
        .navigationDestination(for: BookMetadata.self) { item in
            iOSBookDetailView(item: item, mediaKind: .ebook)
                .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        }
        .navigationDestination(for: PlayerBookData.self) { bookData in
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
}

struct CollectionNavIdentifier: Hashable {
    let id: String
    let name: String
}

struct CollectionsListView: View {
    @Binding var searchText: String
    @Binding var navigationPath: NavigationPath
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = SettingsViewModel()

    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    collectionContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Custom Collections")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func navigateToCollection(_ identifier: CollectionNavIdentifier) {
        navigationPath.append(identifier)
    }

    @ViewBuilder
    private func collectionContent(contentWidth: CGFloat) -> some View {
        let collectionGroups = mediaViewModel.booksByCollection(for: .ebook)
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
            Text(
                "Books in collections will appear here. Create collections on Storyteller to organize your library."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
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
            if collectionNameMatches {
                return (collection: group.collection, books: group.books)
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
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
        let collectionId = collection?.uuid ?? collection?.name ?? ""
        let collectionName = collection?.name ?? "Unknown Collection"
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let navIdentifier = CollectionNavIdentifier(id: collectionId, name: collectionName)

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: books,
                mediaKind: .ebook,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                onSelect: { _ in
                    navigateToCollection(navIdentifier)
                },
                onInfo: { _ in }
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                Button {
                    navigateToCollection(navIdentifier)
                } label: {
                    Text(collectionName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
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
}

struct AuthorsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private let tileWidth: CGFloat = 150
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    authorContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Authors")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func authorContent(contentWidth: CGFloat) -> some View {
        let authorGroups = mediaViewModel.booksByAuthor(for: .ebook)
        let filteredGroups = filterAuthors(authorGroups)
        let columns = calculateColumns(contentWidth: contentWidth)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                    authorCard(author: group.author, books: group.books)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No authors found")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(
                "Books with author information will appear here. Add media via Settings or the More tab."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
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
            if authorNameMatches {
                return (author: group.author, books: group.books)
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func authorCard(author: BookCreator?, books: [BookMetadata]) -> some View {
        VStack(spacing: 12) {
            NavigationLink(value: author?.name ?? "Unknown Author") {
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

            VStack(alignment: .center, spacing: 6) {
                Text(author?.name ?? "Unknown Author")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: tileWidth)
        }
    }
}

struct OfflineStatusSheet: View {
    let onGoToDownloads: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Not Connected")
                    .font(.title2.weight(.semibold))

                Text(
                    "You are currently not connected to the server. Only downloaded books are available for reading."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Button(action: onGoToDownloads) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Go to Downloads")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding(24)
    }
}

struct IOSLibraryToolbarModifier: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if mediaViewModel.lastNetworkOpSucceeded == false {
                            Button {
                                showOfflineSheet = true
                            } label: {
                                Image(systemName: "wifi.slash")
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
    }
}

extension View {
    func iOSLibraryToolbar(showSettings: Binding<Bool>, showOfflineSheet: Binding<Bool>)
        -> some View
    {
        modifier(
            IOSLibraryToolbarModifier(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet
            )
        )
    }
}

struct CarPlayNowPlayingBanner: View {
    let bookTitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "car.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Now playing on CarPlay")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))

                    Text(bookTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                Spacer()

                Text("Tap to join")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}
#endif
