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
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    public init() {}

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
        .onChange(of: searchText) { oldValue, newValue in
            if selectedTab == .home && newValue.count >= 2 && oldValue.count < 2 {
                selectedTab = .books
            }
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
                                    .foregroundColor(.red)
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
                showOfflineSheet: $showOfflineSheet
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
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var isWatchPaired = false

    enum MoreDestination: Hashable {
        case authors
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
                                .foregroundColor(.red)
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
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .center, spacing: 6) {
                Text(author?.name ?? "Unknown Author")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Not Connected")
                    .font(.title2.weight(.semibold))

                Text(
                    "You are currently not connected to the server. Only downloaded books are available for reading."
                )
                .font(.body)
                .foregroundColor(.secondary)
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
                                    .foregroundColor(.red)
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
#endif
