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
    @State private var activeInfoItem: BookMetadata? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var navigationPath = NavigationPath()

    private let sidebarWidth: CGFloat = 340
    private let sidebarSpacing: CGFloat = 1
    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

    var body: some View {
        NavigationStack(path: $navigationPath) {
            seriesListView
                #if os(iOS)
            .navigationTitle("Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if mediaViewModel.lastNetworkOpSucceeded == false,
                            let showOfflineSheet
                        {
                            Button {
                                showOfflineSheet.wrappedValue = true
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

            HStack(spacing: sidebarSpacing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        headerView

                        seriesContent(contentWidth: contentWidth)
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
            Text("Books by Series")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Spacer()
        }
    }

    @ViewBuilder
    private func seriesContent(contentWidth: CGFloat) -> some View {
        let seriesGroups = mediaViewModel.booksBySeries(for: mediaKind)
        let filteredGroups = filterSeries(seriesGroups)

        ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
            seriesSection(
                series: group.series,
                books: group.books,
                contentWidth: contentWidth
            )
        }
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

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: mediaKind,
                availableWidth: stackWidth,
                onSelect: { book in
                    if let seriesName = series?.name {
                        navigateToSeries(seriesName)
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
                    if let seriesName = series?.name {
                        navigateToSeries(seriesName)
                    }
                } label: {
                    Text(series?.name ?? "No Series")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .disabled(series == nil)
                .frame(maxWidth: .infinity, alignment: .center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
        #if os(iOS)
        MediaGridView(
            title: seriesName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: seriesName,
            statusFilter: nil,
            defaultSort: "seriesPosition",
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(seriesName)
        #else
        MediaGridView(
            title: seriesName,
            searchText: "",
            mediaKind: mediaKind,
            tagFilter: nil,
            seriesFilter: seriesName,
            statusFilter: nil,
            defaultSort: "seriesPosition",
            preferredTileWidth: 120,
            minimumTileWidth: 50,
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(seriesName)
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
