#if os(iOS)
import SwiftUI

public enum ConfigurableTab: String, CaseIterable, Identifiable {
    case books
    case series
    case authors
    case narrators
    case tags
    case collections
    case downloaded
    case translators
    case publicationYears
    case ratings

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .books: "Books"
            case .series: "Series"
            case .authors: "Authors"
            case .narrators: "Narrators"
            case .tags: "Tags"
            case .collections: "Collections"
            case .downloaded: "Downloaded"
            case .translators: "Translators"
            case .publicationYears: "Publication Year"
            case .ratings: "Ratings"
        }
    }

    public var iconName: String {
        switch self {
            case .books: "books.vertical.fill"
            case .series: "square.stack.fill"
            case .authors: "person.2.fill"
            case .narrators: "mic.fill"
            case .tags: "tag.fill"
            case .collections: "rectangle.stack"
            case .downloaded: "arrow.down.circle.fill"
            case .translators: "character.book.closed.fill"
            case .publicationYears: "calendar"
            case .ratings: "star.fill"
        }
    }
}

public struct iOSLibraryView: View {
    @State private var searchText: String = ""
    @State private var selectedTab: Tab = .home
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    @State private var selectedItem: SidebarItemDescription? = nil
    @State private var moreNavigationPath = NavigationPath()
    @State private var collectionsNavigationPath = NavigationPath()
    @State private var booksNavigationPath = NavigationPath()
    @State private var downloadedNavigationPath = NavigationPath()
    @State private var showCarPlayPlayer: Bool = false
    @State private var metadataEditorData: MetadataEditorData?
    @State private var metadataEditorHasUnsavedChanges = false
    @State private var showMetadataEditorCloseWarning = false
    @State private var showMetadataPermissionError = false
    @State private var metadataPermissionErrorMessage = ""
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.iOSLibrary") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    public init() {}

    private var carPlayBook: BookMetadata? {
        guard let bookId = CarPlayCoordinator.shared.activeBookId else { return nil }
        return mediaViewModel.library.bookMetaData.first { $0.id == bookId }
    }

    private var connectionErrorType: OfflineStatusSheet.ErrorType {
        if case .error(let message) = mediaViewModel.connectionStatus {
            return .authError(message)
        }
        return .networkOffline
    }

    private var hasConnectionError: Bool {
        mediaViewModel.lastNetworkOpSucceeded == false
            || {
                if case .error = mediaViewModel.connectionStatus { return true }
                return false
            }()
    }

    private var connectionErrorIcon: String {
        if case .error = mediaViewModel.connectionStatus {
            return "exclamationmark.triangle"
        }
        return "wifi.slash"
    }

    enum Tab: Hashable {
        case home
        case slot1
        case slot2
        case more
    }

    private var slot1Tab: ConfigurableTab {
        ConfigurableTab(rawValue: settingsViewModel.tabBarSlot1) ?? .books
    }

    private var slot2Tab: ConfigurableTab {
        ConfigurableTab(rawValue: settingsViewModel.tabBarSlot2) ?? .series
    }

    private func tabLabel(for tab: Tab) -> String {
        switch tab {
            case .home: "Home"
            case .slot1: slot1Tab.label
            case .slot2: slot2Tab.label
            case .more: "More"
        }
    }

    private func tabIcon(for tab: Tab) -> String {
        switch tab {
            case .home: "house.fill"
            case .slot1: slot1Tab.iconName
            case .slot2: slot2Tab.iconName
            case .more: "ellipsis.circle.fill"
        }
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem {
                    Label(tabLabel(for: .home), systemImage: tabIcon(for: .home))
                }
                .tag(Tab.home)

            configurableTabView(for: slot1Tab)
                .tabItem {
                    Label(tabLabel(for: .slot1), systemImage: tabIcon(for: .slot1))
                }
                .tag(Tab.slot1)

            configurableTabView(for: slot2Tab)
                .tabItem {
                    Label(tabLabel(for: .slot2), systemImage: tabIcon(for: .slot2))
                }
                .tag(Tab.slot2)

            moreTab
                .tabItem {
                    Label(tabLabel(for: .more), systemImage: tabIcon(for: .more))
                }
                .tag(Tab.more)
        }
        .environment(\.editMetadataAction, handleEditMetadata)
        .id("\(settingsViewModel.tabBarSlot1)-\(settingsViewModel.tabBarSlot2)")
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
                errorType: connectionErrorType,
                onRetry: {
                    let _ = await BookServiceActor.shared.fetchLibraryInformation()
                    if !hasConnectionError {
                        await MainActor.run {
                            showOfflineSheet = false
                        }
                        return true
                    }
                    return false
                },
                onGoToDownloads: {
                    showOfflineSheet = false
                    selectedTab = .more
                    moreNavigationPath.append(MoreMenuView.MoreDestination.downloaded)
                },
                onGoToSettings: {
                    showOfflineSheet = false
                    showSettings = true
                },
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(
            item: $metadataEditorData,
            onDismiss: {
                metadataEditorData = nil
                metadataEditorHasUnsavedChanges = false
            },
        ) { metadataEditorData in
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Metadata")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        closeMetadataEditor()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                MetadataEditorView(
                    initialBookIds: metadataEditorData.bookIds,
                    hasUnsavedChanges: $metadataEditorHasUnsavedChanges,
                )
                .environment(mediaViewModel)
            }
            .interactiveDismissDisabled(metadataEditorHasUnsavedChanges)
            .alert(
                "Discard unsaved metadata changes?",
                isPresented: $showMetadataEditorCloseWarning,
            ) {
                Button("Discard Changes", role: .destructive) {
                    metadataEditorHasUnsavedChanges = false
                    self.metadataEditorData = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Closing the metadata editor will lose any unsaved changes.")
            }
        }
        .alert("Edit Metadata", isPresented: $showMetadataPermissionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(metadataPermissionErrorMessage)
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
                let variant: MediaViewModel.CoverVariant =
                    book.hasAvailableAudiobook ? .audioSquare : .standard
                let cover = mediaViewModel.coverImage(for: book, variant: variant)
                let ebookCover =
                    book.hasAvailableAudiobook
                    ? mediaViewModel.coverImage(for: book, variant: .standard)
                    : nil
                NavigationStack {
                    playerView(
                        for: PlayerBookData(
                            metadata: book,
                            localMediaPath: path,
                            category: category,
                            coverArt: cover,
                            ebookCoverArt: ebookCover,
                        )
                    )
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

    private func closeMetadataEditor() {
        if metadataEditorHasUnsavedChanges {
            showMetadataEditorCloseWarning = true
        } else {
            metadataEditorData = nil
        }
    }

    private func handleEditMetadata(bookIds: [String]) {
        if bookIds.contains(where: { mediaViewModel.isLocalStandaloneBook($0) }) {
            metadataPermissionErrorMessage =
                "Editing metadata for local books is not supported yet."
            showMetadataPermissionError = true
            return
        }

        Task {
            let sourceIDs = mediaViewModel.sourceIDs(for: bookIds)
            let result = await checkMetadataEditPermission(sourceIDs: sourceIDs)
            await MainActor.run {
                switch result {
                    case .allowed:
                        Task {
                            await Task.yield()
                            metadataEditorData = MetadataEditorData(bookIds: bookIds)
                        }
                    case .denied:
                        metadataPermissionErrorMessage =
                            "Your account does not have permission to edit metadata on this server."
                        showMetadataPermissionError = true
                    case .error(let message):
                        metadataPermissionErrorMessage =
                            "Could not verify server permissions: \(message)"
                        showMetadataPermissionError = true
                }
            }
        }
    }

    private func checkMetadataEditPermission(sourceIDs: [BookSourceID]) async
        -> StorytellerActor.PermissionCheckResult
    {
        let idsToCheck: [BookSourceID?] = sourceIDs.isEmpty ? [nil] : sourceIDs.map { $0 }
        for sourceID in idsToCheck {
            let result = await BookServiceActor.shared.checkBookUpdatePermission(
                sourceID: sourceID
            )
            if case .allowed = result {
                continue
            }
            return result
        }
        return .allowed
    }

    private var homeTab: some View {
        HomeView(
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    @ViewBuilder
    private func configurableTabView(for tab: ConfigurableTab) -> some View {
        switch tab {
            case .books:
                booksTabContent
            case .series:
                seriesTabContent
            case .authors:
                authorsTabContent
            case .narrators:
                narratorsTabContent
            case .tags:
                tagsTabContent
            case .collections:
                collectionsTabContent
            case .downloaded:
                downloadedTabContent
            case .translators:
                translatorsTabContent
            case .publicationYears:
                publicationYearsTabContent
            case .ratings:
                ratingsTabContent
        }
    }

    private var booksTabContent: some View {
        NavigationStack(path: $booksNavigationPath) {
            BooksContentView(searchText: searchText)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search",
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
        }
        .environment(\.mediaNavigationPath, $booksNavigationPath)
    }

    private var seriesTabContent: some View {
        SeriesView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var authorsTabContent: some View {
        AuthorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var narratorsTabContent: some View {
        NarratorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var tagsTabContent: some View {
        TagView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var collectionsTabContent: some View {
        CollectionsView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var downloadedTabContent: some View {
        NavigationStack(path: $downloadedNavigationPath) {
            DownloadedContentView(searchText: searchText)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search",
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
        }
        .environment(\.mediaNavigationPath, $downloadedNavigationPath)
    }

    private var translatorsTabContent: some View {
        TranslatorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var publicationYearsTabContent: some View {
        PublicationYearView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var ratingsTabContent: some View {
        RatingView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var moreTab: some View {
        NavigationStack(path: $moreNavigationPath) {
            MoreMenuView(
                searchText: $searchText,
                showSettings: $showSettings,
                showOfflineSheet: $showOfflineSheet,
                navigationPath: $moreNavigationPath,
                excludedTabs: [slot1Tab, slot2Tab],
            )
        }
        .environment(\.mediaNavigationPath, $moreNavigationPath)
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
    var excludedTabs: [ConfigurableTab] = []
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var isWatchPaired = false

    @State private var hasIncompleteDownloads = false

    enum MoreDestination: Hashable {
        case books
        case series
        case authors
        case narrators
        case tags
        case collections
        case downloaded
        case translators
        case publicationYears
        case ratings
        case currentlyDownloading
        case addLocalFile
        case appleWatch
    }

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

    private func isExcluded(_ tab: ConfigurableTab) -> Bool {
        excludedTabs.contains(tab)
    }

    var body: some View {
        List {
            Section {
                if !isExcluded(.books) {
                    NavigationLink(value: MoreDestination.books) {
                        Label("Books", systemImage: "books.vertical.fill")
                    }
                }
                if !isExcluded(.series) {
                    NavigationLink(value: MoreDestination.series) {
                        Label("Series", systemImage: "square.stack.fill")
                    }
                }
                if !isExcluded(.authors) {
                    NavigationLink(value: MoreDestination.authors) {
                        Label("Authors", systemImage: "person.2.fill")
                    }
                }
                if !isExcluded(.narrators) {
                    NavigationLink(value: MoreDestination.narrators) {
                        Label("Narrators", systemImage: "mic.fill")
                    }
                }
                if !isExcluded(.tags) {
                    NavigationLink(value: MoreDestination.tags) {
                        Label("Tags", systemImage: "tag.fill")
                    }
                }
                if !isExcluded(.collections) {
                    NavigationLink(value: MoreDestination.collections) {
                        Label("Collections", systemImage: "rectangle.stack")
                    }
                }
                if !isExcluded(.translators) {
                    NavigationLink(value: MoreDestination.translators) {
                        Label("Translators", systemImage: "character.book.closed.fill")
                    }
                }
                if !isExcluded(.publicationYears) {
                    NavigationLink(value: MoreDestination.publicationYears) {
                        Label("Publication Year", systemImage: "calendar")
                    }
                }
                if !isExcluded(.ratings) {
                    NavigationLink(value: MoreDestination.ratings) {
                        Label("Ratings", systemImage: "star.fill")
                    }
                }
                if !isExcluded(.downloaded) {
                    NavigationLink(value: MoreDestination.downloaded) {
                        Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    }
                }
                if hasIncompleteDownloads {
                    NavigationLink(value: MoreDestination.currentlyDownloading) {
                        Label("Currently Downloading", systemImage: "arrow.down.circle.dotted")
                    }
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
            let downloads = await DownloadManager.shared.incompleteDownloads
            hasIncompleteDownloads = !downloads.isEmpty

            let _ = await DownloadManager.shared.addObserver { records in
                hasIncompleteDownloads = records.contains { $0.isIncomplete }
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if hasConnectionError {
                        Button {
                            showOfflineSheet = true
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
        .navigationDestination(for: MoreDestination.self) { destination in
            switch destination {
                case .books:
                    BooksContentView(searchText: searchText)
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                        .searchable(
                            text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search",
                        )
                case .series:
                    MoreSeriesView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .authors:
                    MoreAuthorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .narrators:
                    MoreNarratorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .tags:
                    MoreTagsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .translators:
                    MoreTranslatorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .publicationYears:
                    MorePublicationYearsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .ratings:
                    MoreRatingsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .collections:
                    MoreCollectionsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .downloaded:
                    DownloadedContentView(searchText: searchText)
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                        .searchable(
                            text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search",
                        )
                case .currentlyDownloading:
                    CurrentlyDownloadingView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                case .addLocalFile:
                    ImportLocalFileView()
                        .navigationTitle("Manage Local Files")
                        .navigationBarTitleDisplayMode(.inline)
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                case .appleWatch:
                    WatchTransferView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
            }
        }
        .libraryNavigationDestinations(
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }
}

struct CollectionNavIdentifier: Hashable {
    let id: String
    let name: String
}

struct BooksContentView: View {
    let searchText: String

    var body: some View {
        MediaGridView(
            title: "All Books",
            searchText: searchText,
            mediaKind: .ebook,
            viewOptionsKey: "books.ios",
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
        )
        .navigationTitle("Books")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedContentView: View {
    let searchText: String

    var body: some View {
        MediaGridView(
            title: "Downloaded",
            searchText: searchText,
            mediaKind: .ebook,
            viewOptionsKey: "downloaded",
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
            initialLocationFilter: .downloaded,
        )
        .navigationTitle("Downloaded")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CollectionsListView: View {
    @Binding var searchText: String
    @Binding var navigationPath: NavigationPath
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.collections") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

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
        .navigationTitle("Server Collections")
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
                    contentWidth: contentWidth,
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
        contentWidth: CGFloat,
    )
        -> some View
    {
        let collectionId = collection?.uuid ?? collection?.name ?? ""
        let collectionName = collection?.name ?? "Unknown Collection"
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let navIdentifier = CollectionNavIdentifier(id: collectionId, name: collectionName)
        let displayBooks = Array(books.prefix(30))

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: .ebook,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                coverPreference: coverPreference,
                onSelect: { _ in
                    navigateToCollection(navIdentifier)
                },
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

struct AuthorsRowListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var authorGroups: [(author: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByAuthor(for: .ebook)
    }

    private var filteredGroups: [(author: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return authorGroups }
        let searchLower = searchText.lowercased()
        return authorGroups.compactMap { group in
            let authorMatches = group.author?.name?.lowercased().contains(searchLower) ?? false
            if authorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.author?.name) { group in
                    let authorName = group.author?.name ?? "Unknown Author"
                    NavigationLink(value: authorName) {
                        CategoryRowContent(
                            iconName: "person.fill",
                            name: authorName,
                            bookCount: group.books.count,
                            isSelected: false,
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
    }
}

struct SeriesContentView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.series") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    seriesContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func seriesContent(contentWidth: CGFloat) -> some View {
        let seriesGroups = mediaViewModel.booksBySeries(for: .ebook)
        let filteredGroups = filterSeries(seriesGroups)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                seriesSection(
                    series: group.series,
                    books: group.books,
                    contentWidth: contentWidth,
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No series found")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(
                "Books with series information will appear here."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }

    private func filterSeries(
        _ groups: [(series: BookSeries?, books: [BookMetadata])]
    ) -> [(series: BookSeries?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let seriesNameMatches =
                group.series?.name.lowercased().contains(searchLower) ?? false
            if seriesNameMatches {
                return (series: group.series, books: group.books)
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (series: group.series, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func seriesSection(
        series: BookSeries?,
        books: [BookMetadata],
        contentWidth: CGFloat,
    ) -> some View {
        let seriesName = series?.name ?? "Unknown Series"
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let displayBooks = Array(books.prefix(30))

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: .ebook,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                coverPreference: coverPreference,
                onSelect: { _ in },
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                NavigationLink(value: SeriesNavIdentifier(name: seriesName)) {
                    Text(seriesName)
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

struct OfflineStatusSheet: View {
    enum ErrorType: Equatable {
        case networkOffline
        case authError(String)
    }

    let errorType: ErrorType
    let onRetry: () async -> Bool
    let onGoToDownloads: () -> Void
    let onGoToSettings: (() -> Void)?

    @State private var isRetrying = false

    init(
        errorType: ErrorType = .networkOffline,
        onRetry: @escaping () async -> Bool,
        onGoToDownloads: @escaping () -> Void,
        onGoToSettings: (() -> Void)? = nil,
    ) {
        self.errorType = errorType
        self.onRetry = onRetry
        self.onGoToDownloads = onGoToDownloads
        self.onGoToSettings = onGoToSettings
    }

    private var icon: String {
        switch errorType {
            case .networkOffline: return "wifi.slash"
            case .authError: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch errorType {
            case .networkOffline: return "Not Connected"
            case .authError: return "Connection Error"
        }
    }

    private var message: String {
        switch errorType {
            case .networkOffline:
                return
                    "You are currently not connected to the server. Only downloaded books are available for reading."
            case .authError(let details):
                return
                    "Unable to connect to the server: \(details). Please check your server credentials in Settings."
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if case .authError = errorType, let onGoToSettings {
                    Button(action: onGoToSettings) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Go to Settings")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button {
                        isRetrying = true
                        Task {
                            let _ = await onRetry()
                            isRetrying = false
                        }
                    } label: {
                        HStack {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Retry")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetrying)

                    Button(action: onGoToDownloads) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Downloads")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
        }
        .padding(24)
    }
}

extension OfflineStatusSheet.ErrorType {
    var isAuthError: Bool {
        if case .authError = self { return true }
        return false
    }
}

struct IOSLibraryToolbarModifier: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

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

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if hasConnectionError {
                            Button {
                                showOfflineSheet = true
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
    }
}

extension View {
    func iOSLibraryToolbar(showSettings: Binding<Bool>, showOfflineSheet: Binding<Bool>)
        -> some View
    {
        modifier(
            IOSLibraryToolbarModifier(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet,
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

struct LibraryNavigationDestinations: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: .ebook)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
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
            .navigationDestination(for: String.self) { authorName in
                MediaGridView(
                    title: authorName,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "authorView.ebook",
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
                )
                .navigationTitle(authorName)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: SeriesNavIdentifier.self) { series in
                MediaGridView(
                    title: series.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "seriesView.ebook",
                    tagFilter: nil,
                    seriesFilter: series.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(series.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: CollectionNavIdentifier.self) { collection in
                MediaGridView(
                    title: collection.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "collectionsView.ebook",
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
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(collection.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: NarratorNavIdentifier.self) { narrator in
                MediaGridView(
                    title: narrator.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "narratorView.ebook",
                    tagFilter: nil,
                    seriesFilter: nil,
                    authorFilter: nil,
                    narratorFilter: narrator.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(narrator.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: TagNavIdentifier.self) { tag in
                MediaGridView(
                    title: tag.name.capitalized,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "tagView.ebook",
                    tagFilter: tag.name,
                    seriesFilter: nil,
                    authorFilter: nil,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(tag.name.capitalized)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: TranslatorNavIdentifier.self) { translator in
                MediaGridView(
                    title: translator.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "translatorView.ebook",
                    translatorFilter: translator.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(translator.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: PublicationYearNavIdentifier.self) { year in
                MediaGridView(
                    title: year.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "publicationYearView.ebook",
                    publicationYearFilter: year.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(year.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: RatingNavIdentifier.self) { rating in
                MediaGridView(
                    title: rating.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "ratingView.ebook",
                    ratingFilter: rating.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(rating.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
    }
}

struct NarratorsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var narratorGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByNarrator(for: .ebook)
    }

    private var filteredGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return narratorGroups }
        let searchLower = searchText.lowercased()
        return narratorGroups.compactMap { group in
            let narratorMatches = group.narrator?.name?.lowercased().contains(searchLower) ?? false
            if narratorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (narrator: group.narrator, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.narrator?.name) { group in
                    let narratorName = group.narrator?.name ?? "Unknown Narrator"
                    NavigationLink(value: NarratorNavIdentifier(name: narratorName)) {
                        CategoryRowContent(
                            iconName: "mic.fill",
                            name: narratorName,
                            bookCount: group.books.count,
                            isSelected: false,
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
    }
}

struct NarratorNavIdentifier: Hashable {
    let name: String
}

struct TagsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var tagGroups: [(tag: String, books: [BookMetadata])] {
        mediaViewModel.booksByTag(for: .ebook)
    }

    private var filteredGroups: [(tag: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return tagGroups }
        let searchLower = searchText.lowercased()
        return tagGroups.compactMap { group in
            let tagMatches = group.tag.lowercased().contains(searchLower)
            if tagMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (tag: group.tag, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.tag) { group in
                    NavigationLink(value: TagNavIdentifier(name: group.tag)) {
                        CategoryRowContent(
                            iconName: "tag.fill",
                            name: group.tag,
                            bookCount: group.books.count,
                            isSelected: false,
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
    }
}

struct TagNavIdentifier: Hashable {
    let name: String
}

struct TranslatorNavIdentifier: Hashable {
    let name: String
}

struct PublicationYearNavIdentifier: Hashable {
    let name: String
}

struct RatingNavIdentifier: Hashable {
    let name: String
}

struct TranslatorsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var translatorGroups: [(translator: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByTranslator(for: .ebook)
    }

    private var filteredGroups: [(translator: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return translatorGroups }
        let searchLower = searchText.lowercased()
        return translatorGroups.compactMap { group in
            let translatorMatches =
                group.translator?.name?.lowercased().contains(searchLower) ?? false
            if translatorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (translator: group.translator, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.translator?.name) { group in
                    let translatorName = group.translator?.name ?? "Unknown Translator"
                    NavigationLink(value: TranslatorNavIdentifier(name: translatorName)) {
                        CategoryRowContent(
                            iconName: "character.book.closed.fill",
                            name: translatorName,
                            bookCount: group.books.count,
                            isSelected: false,
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
        .navigationTitle("Translators")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PublicationYearsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var yearGroups: [(year: String, books: [BookMetadata])] {
        mediaViewModel.booksByPublicationYear(for: .ebook)
    }

    private var filteredGroups: [(year: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return yearGroups }
        let searchLower = searchText.lowercased()
        return yearGroups.compactMap { group in
            let yearMatches = group.year.lowercased().contains(searchLower)
            if yearMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (year: group.year, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.year) { group in
                    NavigationLink(value: PublicationYearNavIdentifier(name: group.year)) {
                        CategoryRowContent(
                            iconName: "calendar",
                            name: group.year,
                            bookCount: group.books.count,
                            isSelected: false,
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
        .navigationTitle("Publication Year")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RatingsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var ratingGroups: [(rating: String, books: [BookMetadata])] {
        mediaViewModel.booksByRating(for: .ebook)
    }

    private var filteredGroups: [(rating: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return ratingGroups }
        let searchLower = searchText.lowercased()
        return ratingGroups.compactMap { group in
            let ratingMatches = group.rating.lowercased().contains(searchLower)
            if ratingMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (rating: group.rating, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.rating) { group in
                    NavigationLink(value: RatingNavIdentifier(name: group.rating)) {
                        CategoryRowContent(
                            iconName: "star.fill",
                            name: RatingDisplayHelper.label(for: group.rating),
                            bookCount: group.books.count,
                            isSelected: false,
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
        .navigationTitle("Ratings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func libraryNavigationDestinations(
        showSettings: Binding<Bool>,
        showOfflineSheet: Binding<Bool>,
    )
        -> some View
    {
        modifier(
            LibraryNavigationDestinations(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet,
            )
        )
    }
}

// MARK: - More Menu Category Views with Layout Switching

struct MoreSeriesView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.series") private var layoutStyleRaw: String = CategoryLayoutStyle.fan
        .rawValue
    @AppStorage("coverPref.series") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("series.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .fan
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    static let noSeriesFilterKey = BookMetadata.noSeriesSentinel

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksBySeries(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.series?.name ?? "No Series"
            let id = group.series?.name ?? Self.noSeriesFilterKey
            return CategoryGroup(id: id, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(series: BookSeries?, books: [BookMetadata])]) -> [(
        series: BookSeries?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let nameMatches = group.series?.name.lowercased().contains(searchLower) ?? false
            if nameMatches { return group }
            let filteredBooks = group.books.filter {
                $0.title.lowercased().contains(searchLower)
                    || $0.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (series: group.series, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: SeriesNavIdentifier(name: group.id)) {
                            CategoryRowContent(
                                iconName: "books.vertical.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToSeries(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(SeriesNavIdentifier(name: group.id))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToSeries(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToSeries(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Series").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreCollectionsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.collections") private var layoutStyleRaw: String = CategoryLayoutStyle
        .fan.rawValue
    @AppStorage("coverPref.collections") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("collections.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .fan
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByCollection(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.collection?.name ?? "Unknown Collection"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(
        _ groups: [(collection: BookCollectionSummary?, books: [BookMetadata])]
    ) -> [(collection: BookCollectionSummary?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let collectionMatches =
                group.collection?.name.lowercased().contains(searchLower) ?? false
            if collectionMatches { return group }
            let filteredBooks = group.books.filter {
                $0.title.lowercased().contains(searchLower)
                    || $0.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (collection: group.collection, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(
                            value: CollectionNavIdentifier(id: group.id, name: group.name)
                        ) {
                            CategoryRowContent(
                                iconName: "rectangle.stack.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToCollection(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(
            CollectionNavIdentifier(id: group.id, name: group.name)
        )
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToCollection(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToCollection(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Collections").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreAuthorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.authors") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.authors") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("authors.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByAuthor(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.author?.name ?? "Unknown Author"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(author: BookCreator?, books: [BookMetadata])]) -> [(
        author: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let authorMatches = group.author?.name?.lowercased().contains(searchLower) ?? false
            if authorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Authors")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: group.name) {
                            CategoryRowContent(
                                iconName: "person.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToAuthor(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(group.name)
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToAuthor(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToAuthor(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authors").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreNarratorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.narrators") private var layoutStyleRaw: String = CategoryLayoutStyle
        .list.rawValue
    @AppStorage("coverPref.narrators") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("narrators.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByNarrator(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.narrator?.name ?? "Unknown Narrator"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(narrator: BookCreator?, books: [BookMetadata])]) -> [(
        narrator: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let narratorMatches = group.narrator?.name?.lowercased().contains(searchLower) ?? false
            if narratorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (narrator: group.narrator, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Narrators")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: NarratorNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "mic.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToNarrator(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(NarratorNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToNarrator(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToNarrator(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Narrators").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreTagsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.tags") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.tags") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("tags.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByTag(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(id: group.tag, name: group.tag, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(tag: String, books: [BookMetadata])]) -> [(
        tag: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let tagMatches = group.tag.lowercased().contains(searchLower)
            if tagMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (tag: group.tag, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: TagNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "tag.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToTag(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(TagNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToTag(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToTag(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreTranslatorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.translators") private var layoutStyleRaw: String = CategoryLayoutStyle
        .list.rawValue
    @AppStorage("coverPref.translators") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("translators.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByTranslator(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.translator?.name ?? "Unknown Translator"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(translator: BookCreator?, books: [BookMetadata])]) -> [(
        translator: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let translatorMatches =
                group.translator?.name?.lowercased().contains(searchLower) ?? false
            if translatorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (translator: group.translator, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Translators")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: TranslatorNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "character.book.closed.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToTranslator(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(TranslatorNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToTranslator(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToTranslator(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translators").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MorePublicationYearsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.years") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.years") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("years.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByPublicationYear(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(id: group.year, name: group.year, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(year: String, books: [BookMetadata])]) -> [(
        year: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let yearMatches = group.year.lowercased().contains(searchLower)
            if yearMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (year: group.year, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Publication Year")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: PublicationYearNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "calendar",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToYear(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(PublicationYearNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToYear(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToYear(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Years").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreRatingsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.ratings") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.ratings") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("ratings.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByRating(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(
                id: group.rating,
                name: RatingDisplayHelper.label(for: group.rating),
                books: group.books,
                pinId: nil,
            )
        }
    }

    private func filterGroups(_ groups: [(rating: String, books: [BookMetadata])]) -> [(
        rating: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let ratingMatches = group.rating.lowercased().contains(searchLower)
            if ratingMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (rating: group.rating, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Ratings")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: RatingNavIdentifier(name: group.id)) {
                            CategoryRowContent(
                                iconName: "star.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToRating(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(RatingNavIdentifier(name: group.id))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToRating(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToRating(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ratings").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

#endif
