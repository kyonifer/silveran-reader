import SwiftUI

struct SeriesView: View {
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

    static let noSeriesFilterKey = "__no_series__"

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
            seriesListView
                #if os(iOS)
            .navigationTitle("Series")
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
                .navigationDestination(for: String.self) { seriesName in
                    seriesDetailView(for: seriesName)
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

    private var seriesListView: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width
            let contentWidth =
                isSidebarVisible
                ? max(containerWidth - sidebarWidth - sidebarSpacing, 0)
                : containerWidth

            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        headerView

                        seriesContent(contentWidth: contentWidth)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
                .frame(width: contentWidth)
                .contentMargins(.trailing, 10, for: .scrollIndicators)
                .modifier(SoftScrollEdgeModifier())

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
            Text("Books by Series")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Spacer()
        }
    }

    @ViewBuilder
    private func seriesContent(contentWidth: CGFloat) -> some View {
        let seriesGroups = mediaViewModel.booksBySeries(for: mediaKind)
        let filteredGroups = filterSeries(seriesGroups)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                seriesSection(
                    series: group.series,
                    books: group.books,
                    contentWidth: contentWidth
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No series found")
                .font(.title)
                .foregroundStyle(.secondary)
            #if os(iOS)
            Text(
                "Books with series information will appear here. Add media via Settings or the More tab."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            #else
            Text(
                "Books with series information will appear here once you add media."
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

    private func filterSeries(_ groups: [(series: BookSeries?, books: [BookMetadata])]) -> [(
        series: BookSeries?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }

        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let seriesNameMatches = group.series?.name.lowercased().contains(searchLower) ?? false

            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
                    || book.series?.contains(where: { $0.name.lowercased().contains(searchLower) })
                        ?? false
            }

            if seriesNameMatches {
                return (series: group.series, books: group.books)
            }

            guard !filteredBooks.isEmpty else { return nil }
            return (series: group.series, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func seriesSection(series: BookSeries?, books: [BookMetadata], contentWidth: CGFloat)
        -> some View
    {
        let displayBooks = (series == nil) ? Array(books.prefix(30)) : books
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let navigationKey = series?.name ?? Self.noSeriesFilterKey

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: mediaKind,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                onSelect: { _ in
                    navigateToSeries(navigationKey)
                },
                onInfo: { book in
                    activeInfoItem = book
                    isSidebarVisible = true
                }
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                Button {
                    navigateToSeries(navigationKey)
                } label: {
                    Text(series?.name ?? "No Series")
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

    private func navigateToSeries(_ seriesName: String) {
        navigationPath.append(seriesName)
    }

    @ViewBuilder
    private func seriesDetailView(for seriesName: String) -> some View {
        let isNoSeries = seriesName == Self.noSeriesFilterKey
        let displayTitle = isNoSeries ? "No Series" : seriesName
        let sortKey = isNoSeries ? "title" : "seriesPosition"

        #if os(iOS)
        MediaGridView(
            title: displayTitle,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: seriesName,
            statusFilter: nil,
            defaultSort: sortKey,
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(displayTitle)
        #else
        MediaGridView(
            title: displayTitle,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: seriesName,
            statusFilter: nil,
            defaultSort: sortKey,
            preferredTileWidth: 120,
            minimumTileWidth: 50,
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(displayTitle)
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
