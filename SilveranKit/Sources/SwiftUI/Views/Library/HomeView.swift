import SwiftUI

struct HomeView: View {
    #if os(iOS)
    @Binding var searchText: String
    #else
    let searchText: String
    #endif
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @Binding var sidebarSections: [SidebarSectionDescription]
    @Binding var selectedSidebarItem: SidebarItemDescription?
    @Binding var showSettings: Bool
    #if os(iOS)
    var showOfflineSheet: Binding<Bool>?
    #endif
    fileprivate struct HomeSection: Identifiable {
        let id = UUID()
        let title: String
        let mediaKind: MediaKind
        let items: [BookMetadata]
        let destination: String
        let tagFilter: String?
        let statusFilter: String?
        let sortOrder: MediaViewModel.StatusSortOrder?
    }

    struct Selection: Equatable {
        var sectionIndex: Int
        var itemID: BookMetadata.ID
    }

    struct SectionFilter: Hashable {
        let title: String
        let mediaKind: MediaKind
        let tagFilter: String?
        let statusFilter: String?
        let sortOrder: MediaViewModel.StatusSortOrder?
    }

    @State private var selection: Selection? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var sections: [HomeSection] = []
    @State private var settingsViewModel = SettingsViewModel()
    #if os(macOS)
    // Workaround for macOS Sequoia bug where parent view's onTapGesture fires after card tap
    @State private var cardTapInProgress: Bool = false
    #endif
    #if os(iOS)
    @State private var navigationPath = NavigationPath()
    #endif

    private let sidebarWidth: CGFloat = 340
    private let sidebarSpacing: CGFloat = 1
    private let horizontalPadding: CGFloat = 24
    private let verticalPadding: CGFloat = 28
    private let sectionSpacing: CGFloat = 36
    private let headerBottomPadding: CGFloat = 12

    var body: some View {
        #if os(iOS)
        NavigationStack(path: $navigationPath) {
            ZStack {
                homeContent
                if searchText.count >= 2 {
                    searchOverlay
                }
            }
            .navigationTitle("Home")
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
            .navigationDestination(for: SectionFilter.self) { filter in
                sectionFilterView(for: filter)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: showOfflineSheet ?? .constant(false)
                    )
            }
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: .ebook)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: showOfflineSheet ?? .constant(false)
                    )
            }
            .navigationDestination(for: PlayerBookData.self) { bookData in
                playerView(for: bookData)
            }
        }
        #else
        ZStack {
            homeContent
            if searchText.count >= 2 {
                searchOverlayMacOS
            }
        }
        #endif
    }

    private var homeContent: some View {
        GeometryReader { geometry in
            let shouldShowSidebar = isSidebarVisible && selectedItem != nil

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            Text("Home")
                                .font(.system(size: 32, weight: .regular, design: .serif))
                                .padding(.horizontal, horizontalPadding)
                                .padding(.bottom, headerBottomPadding)

                            if sections.allSatisfy({ $0.items.isEmpty }) {
                                VStack(spacing: 12) {
                                    Text("No media is available here yet!")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                    #if os(iOS)
                                    Text(
                                        "To get started, go to [Settings](openSettings) to connect a Storyteller server, or use \"Manage Local Files\" in the More tab to add files from your device."
                                    )
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    .tint(.accentColor)
                                    .environment(\.openURL, OpenURLAction { url in
                                        if url.absoluteString == "openSettings" {
                                            showSettings = true
                                            return .handled
                                        }
                                        return .systemAction
                                    })
                                    #else
                                    Text(
                                        "To add some media, use the Media Sources on the left to load either local files or a remote Storyteller server."
                                    )
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    #endif
                                }
                                .frame(maxWidth: 500)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 60)
                                .padding(.horizontal, horizontalPadding)
                            } else {
                                ForEach(Array(sections.enumerated()), id: \.offset) {
                                    index,
                                    section in
                                    #if os(iOS)
                                    HomeSectionRow(
                                        sectionIndex: index,
                                        section: section,
                                        selection: $selection,
                                        isSidebarVisible: $isSidebarVisible,
                                        sidebarSections: $sidebarSections,
                                        selectedSidebarItem: $selectedSidebarItem,
                                        showAudioIndicator: settingsViewModel.showAudioIndicator,
                                        onNavigateToSection: { navigateToSection($0) }
                                    )
                                    .id(section.id)
                                    .padding(.horizontal, horizontalPadding)
                                    #else
                                    HomeSectionRow(
                                        sectionIndex: index,
                                        section: section,
                                        selection: $selection,
                                        isSidebarVisible: $isSidebarVisible,
                                        sidebarSections: $sidebarSections,
                                        selectedSidebarItem: $selectedSidebarItem,
                                        showAudioIndicator: settingsViewModel.showAudioIndicator,
                                        cardTapInProgress: $cardTapInProgress
                                    )
                                    .id(section.id)
                                    .padding(.horizontal, horizontalPadding)
                                    #endif
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if os(macOS)
                        if cardTapInProgress {
                            cardTapInProgress = false
                            return
                        }
                        #endif
                        selection = nil
                        dismissSidebar()
                    }
                    #if os(macOS)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in }
                    )
                    #endif
                }
                if shouldShowSidebar, let item = selectedItem {
                    Color.clear
                        .frame(width: sidebarSpacing, height: geometry.size.height)
                    MediaGridInfoSidebar(
                        item: item,
                        onClose: { dismissSidebar() },
                        onReadNow: { dismissSidebar() },
                        onRename: {},
                        onDelete: { dismissSidebar() },
                    )
                    .frame(width: sidebarWidth, height: geometry.size.height)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        #if os(macOS)
        .focusable(true)
        .focusEffectDisabled(true)
        .onMoveCommand(perform: handleMoveCommand)
        .onKeyPress(.escape) {
            if isSidebarVisible {
                dismissSidebar()
                return .handled
            }
            return .ignored
        }
        #endif
        .onAppear {
            if mediaViewModel.isReady {
                loadSections()
            }
        }
        .onChange(of: selection) { _, _ in
            reconcileSidebarVisibility()
        }
        .onChange(of: mediaViewModel.isReady) {
            if mediaViewModel.isReady {
                loadSections()
            }
        }
        .onChange(of: mediaViewModel.libraryVersion) {
            loadSections()
        }
        .onChange(of: searchText) { _, _ in
            loadSections()
        }
    }

    private func loadSections() {
        sections = [
            makeStatusSection(
                title: "Currently Reading",
                statusName: "Reading",
                sortBy: .recentPositionUpdate,
                limit: 12,
                destination: "Currently Reading"
            ),
            makeStatusSection(
                title: "Start Reading",
                statusName: "To read",
                sortBy: .recentlyAdded,
                limit: 12,
                destination: "Start Reading"
            ),
            makeRecentlyAddedSection(
                title: "Recently Added",
                limit: 12,
                destination: "Recently Added"
            ),
            makeStatusSection(
                title: "Completed",
                statusName: "Read",
                sortBy: .recentPositionUpdate,
                limit: 12,
                destination: "Completed"
            ),
        ]
    }

    private var selectedItem: BookMetadata? {
        guard let selection else { return nil }
        guard sections.indices.contains(selection.sectionIndex) else { return nil }
        let items = sections[selection.sectionIndex].items
        return items.first { $0.id == selection.itemID }
    }

    private func ensureSelection() {
        if let selection, let item = selectedItem,
            sections.indices.contains(selection.sectionIndex),
            item.id == selection.itemID
        {
            return
        }
        selection = firstAvailableSelection()
    }

    private func reconcileSidebarVisibility() {
        guard let selection, selectedItem != nil else {
            isSidebarVisible = false
            return
        }
        if !sections.indices.contains(selection.sectionIndex) {
            isSidebarVisible = false
        }
    }

    private func dismissSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible = false
        }
    }

    private func firstAvailableSelection() -> Selection? {
        for (index, section) in sections.enumerated() {
            if let first = section.items.first {
                return Selection(sectionIndex: index, itemID: first.id)
            }
        }
        return nil
    }

    private func indexOfItem(in sectionIndex: Int, id: BookMetadata.ID) -> Int? {
        guard sections.indices.contains(sectionIndex) else { return nil }
        return sections[sectionIndex].items.firstIndex { $0.id == id }
    }

    private func adjacentSection(from index: Int, step: Int) -> Int? {
        var target = index + step
        while sections.indices.contains(target) {
            if !sections[target].items.isEmpty {
                return target
            }
            target += step
        }
        return nil
    }

    #if os(macOS)
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        ensureSelection()
        guard let currentSelection = selection,
            let currentItemIndex = indexOfItem(
                in: currentSelection.sectionIndex,
                id: currentSelection.itemID
            )
        else {
            return
        }

        let currentSectionIndex = currentSelection.sectionIndex
        let currentItems = sections[currentSectionIndex].items
        guard !currentItems.isEmpty else { return }

        var targetSectionIndex = currentSectionIndex
        var targetItemIndex = currentItemIndex

        switch direction {
            case .left:
                if currentItemIndex > 0 {
                    targetItemIndex = currentItemIndex - 1
                }
            case .right:
                if currentItemIndex < currentItems.count - 1 {
                    targetItemIndex = currentItemIndex + 1
                }
            case .up:
                if let previousSection = adjacentSection(from: currentSectionIndex, step: -1) {
                    let previousItems = sections[previousSection].items
                    let preferredIndex = min(currentItemIndex, previousItems.count - 1)
                    targetSectionIndex = previousSection
                    targetItemIndex = preferredIndex
                }
            case .down:
                if let nextSection = adjacentSection(from: currentSectionIndex, step: 1) {
                    let nextItems = sections[nextSection].items
                    let preferredIndex = min(currentItemIndex, nextItems.count - 1)
                    targetSectionIndex = nextSection
                    targetItemIndex = preferredIndex
                }
            default:
                return
        }

        guard sections.indices.contains(targetSectionIndex) else { return }
        let targetItems = sections[targetSectionIndex].items
        guard !targetItems.isEmpty else { return }
        let clampedItemIndex = min(max(targetItemIndex, 0), targetItems.count - 1)
        let targetItem = targetItems[clampedItemIndex]

        let newSelection = Selection(sectionIndex: targetSectionIndex, itemID: targetItem.id)
        if newSelection != selection {
            selection = newSelection
        }
    }
    #endif

    private func makeSection(
        title: String,
        mediaKind: MediaKind,
        tagFilter: String?,
        limit: Int,
        destination: String
    ) -> HomeSection {
        let baseItems = mediaViewModel.items(
            for: mediaKind,
            narrationFilter: .both,
            tagFilter: tagFilter
        )
        let filtered = baseItems.filter { matchesSearchText($0) }
        let limited = Array(filtered.prefix(limit))
        return HomeSection(
            title: title,
            mediaKind: mediaKind,
            items: limited,
            destination: destination,
            tagFilter: tagFilter,
            statusFilter: nil,
            sortOrder: nil
        )
    }

    private func makeStatusSection(
        title: String,
        statusName: String,
        sortBy: MediaViewModel.StatusSortOrder,
        limit: Int,
        destination: String
    ) -> HomeSection {
        let baseItems = mediaViewModel.itemsByStatus(statusName, sortBy: sortBy, limit: limit)
        let filtered = baseItems.filter { matchesSearchText($0) }
        return HomeSection(
            title: title,
            mediaKind: .ebook,
            items: filtered,
            destination: destination,
            tagFilter: nil,
            statusFilter: statusName,
            sortOrder: sortBy
        )
    }

    private func makeRecentlyAddedSection(
        title: String,
        limit: Int,
        destination: String
    ) -> HomeSection {
        let baseItems = mediaViewModel.recentlyAddedItems(limit: limit)
        let filtered = baseItems.filter { matchesSearchText($0) }
        return HomeSection(
            title: title,
            mediaKind: .ebook,
            items: filtered,
            destination: destination,
            tagFilter: nil,
            statusFilter: nil,
            sortOrder: .recentlyAdded
        )
    }

    private func matchesSearchText(_ item: BookMetadata) -> Bool {
        guard searchText.count >= 2 else { return true }

        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return true }

        let title = item.title.lowercased()
        let authorNames = (item.authors ?? []).compactMap { $0.name?.lowercased() }

        for term in terms {
            let matchesTitle = title.contains(term)
            let matchesAuthor = authorNames.contains { $0.contains(term) }

            if !matchesTitle && !matchesAuthor {
                return false
            }
        }

        return true
    }

    #if os(iOS)
    private func navigateToSection(_ section: HomeSection) {
        let filter = SectionFilter(
            title: section.title,
            mediaKind: section.mediaKind,
            tagFilter: section.tagFilter,
            statusFilter: section.statusFilter,
            sortOrder: section.sortOrder
        )
        navigationPath.append(filter)
    }

    @ViewBuilder
    private func sectionFilterView(for filter: SectionFilter) -> some View {
        MediaGridView(
            title: filter.title,
            searchText: "",
            mediaKind: filter.mediaKind,
            tagFilter: filter.tagFilter,
            seriesFilter: nil,
            statusFilter: filter.statusFilter,
            defaultSort: defaultSortForFilter(filter),
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            scrollPosition: nil
        )
        .navigationTitle(filter.title)
    }

    private func defaultSortForFilter(_ filter: SectionFilter) -> String {
        guard let sortOrder = filter.sortOrder else { return "titleAZ" }
        switch sortOrder {
            case .recentlyAdded:
                return "recentlyAdded"
            case .recentPositionUpdate:
                return "recentlyRead"
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

    private var searchOverlay: some View {
        MediaGridView(
            title: "Search",
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
        .background(Color(uiColor: .systemBackground))
    }
    #endif

    #if os(macOS)
    private var searchOverlayMacOS: some View {
        MediaGridView(
            title: "Search",
            searchText: searchText,
            mediaKind: .ebook,
            tagFilter: nil,
            seriesFilter: nil,
            statusFilter: nil,
            defaultSort: "titleAZ",
            preferredTileWidth: 120,
            minimumTileWidth: 50,
            initialNarrationFilterOption: .both
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif

}

private struct HomeSectionRow: View {
    let sectionIndex: Int
    let section: HomeView.HomeSection
    @Binding var selection: HomeView.Selection?
    @Binding var isSidebarVisible: Bool
    @Binding var sidebarSections: [SidebarSectionDescription]
    @Binding var selectedSidebarItem: SidebarItemDescription?
    let showAudioIndicator: Bool
    #if os(macOS)
    @Binding var cardTapInProgress: Bool
    #endif
    #if os(iOS)
    let onNavigateToSection: (HomeView.HomeSection) -> Void
    #endif

    private let horizontalSpacing: CGFloat = 14
    private let tileWidth: CGFloat = 125

    #if os(macOS)
    @State private var hoveredInfoItemID: BookMetadata.ID? = nil
    #endif

    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var canScrollLeft: Bool = false
    @State private var canScrollRight: Bool = false
    #if os(macOS)
    @State private var scrollOffset: CGFloat = 0
    @State private var lastScrollOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.title2.weight(.semibold))

                #if os(macOS)
                if !section.items.isEmpty {
                    Button {
                        scrollLeft()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canScrollLeft ? Color.secondary : Color.secondary.opacity(0.5))
                    .disabled(!canScrollLeft)

                    Button {
                        scrollRight()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        canScrollRight ? Color.secondary : Color.secondary.opacity(0.5)
                    )
                    .disabled(!canScrollRight)
                }
                #endif

                Spacer()
                Button("See All") {
                    #if os(iOS)
                    onNavigateToSection(section)
                    #else
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible = false
                    }
                    selectSidebarItem(named: section.destination)
                    #endif
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }

            let metrics = MediaItemCardMetrics.make(for: tileWidth, mediaKind: section.mediaKind)

            if section.items.isEmpty {
                VStack {
                    Text("No items currently.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: max(tileWidth * 0.9, 120))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            } else {
                #if os(iOS)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: horizontalSpacing) {
                        ForEach(section.items) { item in
                            card(for: item, metrics: metrics)
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: calculateRowHeight(metrics: metrics))
                #else
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        HStack(alignment: .top, spacing: horizontalSpacing) {
                            ForEach(section.items) { item in
                                card(for: item, metrics: metrics)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .offset(x: scrollOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDragging = true
                                    let newOffset = lastScrollOffset + value.translation.width
                                    let maxOffset: CGFloat = 0
                                    let minOffset = -max(
                                        0,
                                        CGFloat(section.items.count)
                                            * (tileWidth + horizontalSpacing)
                                            - geometry.size.width
                                    )
                                    scrollOffset = min(maxOffset, max(minOffset, newOffset))
                                }
                                .onEnded { value in
                                    isDragging = false
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        let itemWidth = tileWidth + horizontalSpacing
                                        let targetIndex = -scrollOffset / itemWidth
                                        let snappedIndex = round(targetIndex)
                                        scrollOffset = -snappedIndex * itemWidth
                                        lastScrollOffset = scrollOffset
                                    }
                                }
                        )
                    }
                    .frame(height: calculateRowHeight(metrics: metrics))
                    .onAppear {
                        scrollProxy = proxy
                        canScrollLeft = section.items.count > 3
                        canScrollRight = section.items.count > 3
                    }
                    .onChange(of: selection) { _, newSelection in
                        guard let newSelection, newSelection.sectionIndex == sectionIndex else {
                            return
                        }
                        scrollToSelectionIfNeeded(newSelection.itemID, proxy: proxy)
                    }
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private func card(for item: BookMetadata, metrics: MediaItemCardMetrics) -> some View {
        #if os(macOS)
        MediaItemCardView(
            item: item,
            mediaKind: section.mediaKind,
            metrics: metrics,
            isSelected: isItemSelected(item.id),
            showAudioIndicator: showAudioIndicator,
            sourceLabel: nil,
            onSelect: { selected in
                select(selected)
            },
            onInfo: { selected in
                openInfo(for: selected)
            },
            isInfoHovered: hoveredInfoItemID == item.id,
            onInfoHoverChanged: { hovering in
                if hovering {
                    hoveredInfoItemID = item.id
                } else if hoveredInfoItemID == item.id {
                    hoveredInfoItemID = nil
                }
            }
        )
        #else
        MediaItemCardView(
            item: item,
            mediaKind: section.mediaKind,
            metrics: metrics,
            isSelected: isItemSelected(item.id),
            showAudioIndicator: showAudioIndicator,
            sourceLabel: nil,
            onSelect: { selected in
                select(selected)
            },
            onInfo: { selected in
                openInfo(for: selected)
            }
        )
        #endif
    }

    @Environment(MediaViewModel.self) private var mediaViewModel

    private func isItemSelected(_ id: BookMetadata.ID) -> Bool {
        guard let selection else { return false }
        return selection.sectionIndex == sectionIndex && selection.itemID == id
    }

    private func select(_ item: BookMetadata) {
        #if os(macOS)
        cardTapInProgress = true
        #endif
        let newSelection = HomeView.Selection(sectionIndex: sectionIndex, itemID: item.id)
        if selection != newSelection {
            selection = newSelection
        }
    }

    private func openInfo(for item: BookMetadata) {
        select(item)
        if !isSidebarVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSidebarVisible = true
            }
        }
    }

    private func selectSidebarItem(named name: String) {
        for section in sidebarSections {
            for item in section.items {
                if item.name == name {
                    selectedSidebarItem = item
                    return
                }
                for child in item.children ?? [] {
                    if child.name == name {
                        selectedSidebarItem = child
                        return
                    }
                }
            }
        }
    }

    #if os(macOS)
    private func scrollLeft() {
        let itemWidth = tileWidth + horizontalSpacing
        let currentIndex = round(-scrollOffset / itemWidth)
        let targetIndex = max(currentIndex - 1, 0)

        withAnimation(.easeOut(duration: 0.3)) {
            scrollOffset = -targetIndex * itemWidth
            lastScrollOffset = scrollOffset
        }
    }

    private func scrollRight() {
        let itemWidth = tileWidth + horizontalSpacing
        let currentIndex = round(-scrollOffset / itemWidth)
        let targetIndex = min(currentIndex + 1, CGFloat(section.items.count - 1))

        withAnimation(.easeOut(duration: 0.3)) {
            scrollOffset = -targetIndex * itemWidth
            lastScrollOffset = scrollOffset
        }
    }
    #endif

    private func findCurrentVisibleItemIndex() -> Int? {
        guard let selection, selection.sectionIndex == sectionIndex else {
            return 0
        }
        return section.items.firstIndex { $0.id == selection.itemID }
    }

    private func scrollToSelectionIfNeeded(_ itemID: BookMetadata.ID, proxy: ScrollViewProxy) {
        return
    }

    private func calculateRowHeight(metrics: MediaItemCardMetrics) -> CGFloat {
        return metrics.maxCardHeight
    }
}

#Preview {
    StatePreviewWrapper()
}

private struct StatePreviewWrapper: View {
    @State var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    @State var selectedItem: SidebarItemDescription? = nil
    @State var showSettings: Bool = false
    #if os(iOS)
    @State var searchText: String = ""
    #endif
    var body: some View {
        #if os(iOS)
        HomeView(
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings
        )
        #else
        HomeView(
            searchText: "",
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings
        )
        #endif
    }
}
