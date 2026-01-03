import SwiftUI

extension MediaKind {
    var coverAspectRatio: CGFloat {
        switch self {
            case .ebook:
                2.0 / 3.0
            case .audiobook:
                1.0
        }
    }

    var iconName: String {
        switch self {
            case .ebook:
                "books.vertical"
            case .audiobook:
                "headphones"
        }
    }
}

struct MediaGridView: View {
    public struct ColumnBreakpoint: Hashable {
        public let columns: Int
        public let minWidth: CGFloat

        public init(columns: Int, minWidth: CGFloat) {
            self.columns = columns
            self.minWidth = minWidth
        }
    }

    let title: String
    let searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var settingsViewModel = SettingsViewModel()
    let mediaKind: MediaKind
    let tagFilter: String?
    let seriesFilter: String?
    let collectionFilter: String?
    let authorFilter: String?
    let narratorFilter: String?
    let statusFilter: String?
    let defaultSort: String?
    let preferredTileWidth: CGFloat
    let minimumTileWidth: CGFloat
    let columnBreakpoints: [ColumnBreakpoint]
    let onReadNow: (BookMetadata) -> Void
    let onRename: (BookMetadata) -> Void
    let onDelete: (BookMetadata) -> Void
    let initialNarrationFilterOption: NarrationFilter
    private let scrollPosition: Binding<BookMetadata.ID?>?
    private let headerScrollID = "media-grid-header"

    #if os(macOS)
    @State private var hoveredInfoItemID: BookMetadata.ID? = nil
    // Workaround for macOS Sequoia bug where parent view's onTapGesture fires after card tap
    @State private var cardTapInProgress: Bool = false
    #endif

    @State private var activeInfoItem: BookMetadata? = nil
    @State private var isSidebarVisible: Bool = false
    @State private var lastKnownColumnCount: Int = 1
    @State private var selectedSortOption: SortOption
    @State private var selectedFormatFilter: FormatFilterOption
    @State private var selectedTag: String? = nil
    @State private var selectedSeries: String? = nil
    @State private var selectedCollection: String? = nil
    @State private var selectedAuthor: String? = nil
    @State private var selectedNarrator: String? = nil
    @State private var selectedStatus: String? = nil
    @State private var selectedLocation: LocationFilterOption = .all
    @State private var shouldEnsureActiveItemVisible: Bool = false
    @State private var showSourceBadge: Bool = false

    private static let defaultHorizontalSpacing: CGFloat = 16
    private let horizontalSpacing: CGFloat = MediaGridView.defaultHorizontalSpacing
    private let verticalSpacing: CGFloat = 24
    private let gridHorizontalPadding: CGFloat = 16
    private let sidebarWidth: CGFloat = 340
    private let sidebarSpacing: CGFloat = 1
    private let headerFontSize: CGFloat = 32

    #if os(macOS)
    private let platformMinimumWidth: CGFloat = 550
    #else
    // TODO: what floor makes sense here for iOS?
    private let platformMinimumWidth: CGFloat = 0
    #endif

    init(
        title: String,
        searchText: String = "",
        mediaKind: MediaKind = .ebook,
        tagFilter: String? = nil,
        seriesFilter: String? = nil,
        collectionFilter: String? = nil,
        authorFilter: String? = nil,
        narratorFilter: String? = nil,
        statusFilter: String? = nil,
        defaultSort: String? = nil,
        preferredTileWidth: CGFloat = 250,
        minimumTileWidth: CGFloat = 10,
        columnBreakpoints: [ColumnBreakpoint]? = nil,
        onReadNow: ((BookMetadata) -> Void)? = { _ in },
        onRename: ((BookMetadata) -> Void)? = { _ in },
        onDelete: ((BookMetadata) -> Void)? = { _ in },
        initialNarrationFilterOption: NarrationFilter = .both,
        initialLocationFilter: LocationFilterOption = .all,
        scrollPosition: Binding<BookMetadata.ID?>? = nil
    ) {
        self.title = title
        self.searchText = searchText
        self.mediaKind = mediaKind
        self.tagFilter = tagFilter
        self.seriesFilter = seriesFilter
        self.collectionFilter = collectionFilter
        self.authorFilter = authorFilter
        self.narratorFilter = narratorFilter
        self.statusFilter = statusFilter
        self.defaultSort = defaultSort
        self.preferredTileWidth = preferredTileWidth
        self.minimumTileWidth = minimumTileWidth
        let resolvedBreakpoints: [ColumnBreakpoint] =
            if let columnBreakpoints {
                columnBreakpoints.sorted { $0.minWidth < $1.minWidth }
            } else {
                MediaGridView.defaultColumnBreakpoints(
                    preferredTileWidth: preferredTileWidth,
                )
            }
        self.columnBreakpoints = resolvedBreakpoints
        self.onReadNow = onReadNow ?? { _ in }
        self.onRename = onRename ?? { _ in }
        self.onDelete = onDelete ?? { _ in }
        self.initialNarrationFilterOption = initialNarrationFilterOption
        self.scrollPosition = scrollPosition
        _selectedFormatFilter = State(
            initialValue: MediaGridView.mapNarrationToFormatFilter(initialNarrationFilterOption)
        )
        _selectedTag = State(initialValue: tagFilter)
        _selectedSeries = State(initialValue: seriesFilter)
        _selectedCollection = State(initialValue: collectionFilter)
        _selectedAuthor = State(initialValue: authorFilter)
        _selectedNarrator = State(initialValue: narratorFilter)
        _selectedStatus = State(initialValue: statusFilter)
        _selectedLocation = State(initialValue: initialLocationFilter)

        let sortOption: SortOption
        if let defaultSort, let option = SortOption(rawValue: defaultSort) {
            sortOption = option
        } else {
            sortOption = .titleAZ
        }
        _selectedSortOption = State(initialValue: sortOption)
    }

    private static func defaultColumnBreakpoints(preferredTileWidth: CGFloat) -> [ColumnBreakpoint]
    {
        let spacing = defaultHorizontalSpacing
        var breakpoints: [ColumnBreakpoint] = []
        let maxColumns = 10
        guard preferredTileWidth > 0 else {
            return breakpoints
        }

        for columns in 4...maxColumns {
            let width = (preferredTileWidth * CGFloat(columns)) + (spacing * CGFloat(columns - 1))
            breakpoints.append(ColumnBreakpoint(columns: columns, minWidth: width))
        }

        return breakpoints
    }

    private struct LayoutConfiguration {
        let columns: [GridItem]
        let tileWidth: CGFloat
    }

    private func resolvedLayout(for containerWidth: CGFloat) -> LayoutConfiguration {
        let availableWidth = max(0, containerWidth - (gridHorizontalPadding * 2))
        guard availableWidth > 0 else {
            let fallbackColumns = max(columnBreakpoints.first?.columns ?? 1, 1)
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: horizontalSpacing, alignment: .top),
                count: fallbackColumns
            )
            return LayoutConfiguration(
                columns: columns,
                tileWidth: minimumTileWidth,
            )
        }

        var targetColumns =
            columnBreakpoints.last { breakpoint in
                availableWidth >= breakpoint.minWidth
            }?.columns ?? columnBreakpoints.first?.columns ?? 1

        var currentTileWidth = tileWidth(forColumns: targetColumns, availableWidth: availableWidth)

        while currentTileWidth < minimumTileWidth, targetColumns > 1 {
            targetColumns -= 1
            currentTileWidth = tileWidth(forColumns: targetColumns, availableWidth: availableWidth)
        }

        currentTileWidth = max(minimumTileWidth, currentTileWidth)

        let columns = Array(
            repeating: GridItem(
                .fixed(currentTileWidth),
                spacing: horizontalSpacing,
                alignment: .top
            ),
            count: targetColumns
        )
        return LayoutConfiguration(columns: columns, tileWidth: currentTileWidth)
    }

    private func tileWidth(forColumns columnCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return availableWidth }
        let spacingTotal = horizontalSpacing * CGFloat(max(columnCount - 1, 0))
        let usableWidth = max(availableWidth - spacingTotal, 0)
        return usableWidth / CGFloat(columnCount)
    }

    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            let shouldShowSidebar = isSidebarVisible && activeInfoItem != nil
            #else
            let shouldShowSidebar = false
            #endif
            let availableWidth = geometry.size.width
            let detailWidth = sidebarWidth + sidebarSpacing
            let contentWidth =
                shouldShowSidebar
                ? max(availableWidth - detailWidth, 0)
                : max(availableWidth, platformMinimumWidth)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            content(for: max(contentWidth, minimumTileWidth))
                        }
                        .frame(width: max(contentWidth, minimumTileWidth))
                        .contentMargins(.trailing, 10, for: .scrollIndicators)
                        .scrollClipDisabled(true)
                        .modifier(SoftScrollEdgeModifier())
                        .contentShape(Rectangle())
                        .onTapGesture {
                            #if os(macOS)
                            if cardTapInProgress {
                                cardTapInProgress = false
                                return
                            }
                            #endif
                            activeInfoItem = nil
                            dismissSidebar()
                        }
                        #if os(macOS)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in }
                        )
                        #endif
                    }

                    #if os(macOS)
                    if shouldShowSidebar, let activeInfoItem {
                        MediaGridInfoSidebar(
                            item: activeInfoItem,
                            mediaKind: mediaKind,
                            onClose: { dismissSidebar() },
                            onReadNow: {
                                onReadNow(activeInfoItem)
                                dismissSidebar()
                            },
                            onRename: {
                                onRename(activeInfoItem)
                            },
                            onDelete: {
                                onDelete(activeInfoItem)
                                dismissSidebar()
                            },
                        )
                    }
                    #endif
                }
            }
        }
        .frame(minWidth: platformMinimumWidth)
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
    }

    @ViewBuilder
    private func content(for containerWidth: CGFloat) -> some View {
        let layout = resolvedLayout(for: containerWidth)
        let tileMetrics = MediaItemCardMetrics.make(for: layout.tileWidth, mediaKind: mediaKind)
        let columnCount = max(layout.columns.count, 1)

        VStack(alignment: .leading, spacing: verticalSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: headerFontSize, weight: .regular, design: .serif))

                MediaGridSortAndFilterBar(
                    selectedSortOption: $selectedSortOption,
                    selectedFormatFilter: $selectedFormatFilter,
                    selectedTag: $selectedTag,
                    selectedSeries: $selectedSeries,
                    selectedAuthor: $selectedAuthor,
                    selectedNarrator: $selectedNarrator,
                    selectedStatus: $selectedStatus,
                    selectedLocation: $selectedLocation,
                    showAudioIndicator: Binding(
                        get: { settingsViewModel.showAudioIndicator },
                        set: { newValue in
                            settingsViewModel.showAudioIndicator = newValue
                            Task { try? await settingsViewModel.save() }
                        }
                    ),
                    showSourceBadge: $showSourceBadge,
                    availableTags: availableTags,
                    availableSeries: availableSeries,
                    availableAuthors: availableAuthors,
                    availableNarrators: availableNarrators,
                    availableStatuses: availableStatuses,
                    filtersSummaryText: filtersSummaryText
                )
            }
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.leading, 8)

            if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Text("No media is available here yet!")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("To add some media, go to Settings to connect a Storyteller server.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
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
                .padding(.horizontal, gridHorizontalPadding)
            } else {
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: verticalSpacing) {
                    ForEach(displayItems) { item in
                        card(for: item, metrics: tileMetrics)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, gridHorizontalPadding)
            }
        }
        .padding(.vertical)
        .onAppear {
            lastKnownColumnCount = columnCount
        }
        .onChange(of: columnCount) { oldValue, newValue in
            lastKnownColumnCount = newValue
        }
        .onChange(of: selectedFormatFilter) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedTag) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedSeries) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedStatus) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedLocation) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedNarrator) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: selectedSortOption) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: mediaKind) { _, _ in
            reconcileSelectionAfterFiltering()
        }
        .onChange(of: initialNarrationFilterOption) { _, _ in
            selectedFormatFilter =
                MediaGridView.mapNarrationToFormatFilter(initialNarrationFilterOption)
            reconcileSelectionAfterFiltering()
        }
    }

    static func mapNarrationToFormatFilter(_ narration: NarrationFilter) -> FormatFilterOption {
        switch narration {
            case .both: .all
            case .withAudio: .audiobook
            case .withoutAudio: .ebookOnly
        }
    }

    @ViewBuilder
    private func card(for item: BookMetadata, metrics: MediaItemCardMetrics) -> some View {
        let sourceLabel = showSourceBadge ? mediaViewModel.sourceLabel(for: item.id) : nil
        #if os(macOS)
        MediaItemCardView(
            item: item,
            mediaKind: mediaKind,
            metrics: metrics,
            isSelected: activeInfoItem?.id == item.id,
            showAudioIndicator: settingsViewModel.showAudioIndicator,
            sourceLabel: sourceLabel,
            onSelect: { [self] selected in
                selectItem(selected)
            },
            onInfo: { selected in
                openSidebar(for: selected)
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
            mediaKind: mediaKind,
            metrics: metrics,
            isSelected: activeInfoItem?.id == item.id,
            showAudioIndicator: settingsViewModel.showAudioIndicator,
            sourceLabel: sourceLabel,
            onSelect: { selected in
                selectItem(selected)
            },
            onInfo: { selected in
                openSidebar(for: selected)
            }
        )
        #endif
    }

    private func selectItem(_ item: BookMetadata, ensureVisible: Bool = false) {
        #if os(macOS)
        cardTapInProgress = true
        #endif
        let visibleItems = displayItems
        guard visibleItems.contains(where: { $0.id == item.id }) else { return }
        shouldEnsureActiveItemVisible = ensureVisible
        activeInfoItem = item
    }

    private func openSidebar(for item: BookMetadata) {
        activeInfoItem = item
        if !isSidebarVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSidebarVisible = true
            }
        }
    }

    private func dismissSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible = false
        }
    }

    private func reconcileSelectionAfterFiltering() {
        guard let activeInfoItem else { return }
        let visibleItems = displayItems
        if !visibleItems.contains(where: { $0.id == activeInfoItem.id }) {
            clearSelection()
        }
    }

    private func clearSelection() {
        activeInfoItem = nil
        isSidebarVisible = false
    }

    private func scrollToActiveItem(using proxy: ScrollViewProxy) {
        guard let id = activeInfoItem?.id else { return }
        if let binding = scrollPosition {
            binding.wrappedValue = id
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private func restoreScrollPosition(
        using proxy: ScrollViewProxy,
        binding: Binding<BookMetadata.ID?>
    ) {
        let target = binding.wrappedValue ?? headerScrollID
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private var displayItems: [BookMetadata] {
        let base = itemsForCurrentFormatSelection()
        let formatFiltered = base.filter { selectedFormatFilter.matches($0) }
        let tagFiltered = formatFiltered.filter { matchesSelectedTag($0) }
        let seriesFiltered = tagFiltered.filter { matchesSelectedSeries($0) }
        let collectionFiltered = seriesFiltered.filter { matchesSelectedCollection($0) }
        let authorFiltered = collectionFiltered.filter { matchesSelectedAuthor($0) }
        let narratorFiltered = authorFiltered.filter { matchesSelectedNarrator($0) }
        let statusFiltered = narratorFiltered.filter { matchesSelectedStatus($0) }
        let locationFiltered = statusFiltered.filter { matchesSelectedLocation($0) }
        let searchFiltered = locationFiltered.filter { matchesSearchText($0) }
        let sorted =
            searchFiltered.sorted { lhs, rhs in
                if lhs.id == rhs.id { return false }
                let result = selectedSortOption.comparison(lhs, rhs)
                if result == .orderedSame {
                    return lhs.id < rhs.id
                }
                return result == .orderedAscending
            }
        return sorted
    }

    private func itemsForCurrentFormatSelection() -> [BookMetadata] {
        var primary = mediaViewModel.items(
            for: mediaKind,
            narrationFilter: .both,
            tagFilter: tagFilter
        )
        if selectedFormatFilter.includesAudiobookOnlyItems {
            let audioOnlyItems = mediaViewModel.items(
                for: .audiobook,
                narrationFilter: .both,
                tagFilter: tagFilter
            )
            primary = merge(primary, with: audioOnlyItems)
        }
        return primary
    }

    private var catalogItemsForFilters: [BookMetadata] {
        if mediaKind == .audiobook {
            return mediaViewModel.items(
                for: .audiobook,
                narrationFilter: .both,
                tagFilter: tagFilter
            )
        }
        let primary = mediaViewModel.items(
            for: mediaKind,
            narrationFilter: .both,
            tagFilter: tagFilter
        )
        let audioOnly = mediaViewModel.items(
            for: .audiobook,
            narrationFilter: .both,
            tagFilter: tagFilter
        )
        return merge(primary, with: audioOnly)
    }

    private func merge(_ primary: [BookMetadata], with supplemental: [BookMetadata])
        -> [BookMetadata]
    {
        guard !supplemental.isEmpty else { return primary }
        var result = primary
        var seen = Set(result.map(\.id))
        for item in supplemental where !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }

    private func matchesSelectedTag(_ item: BookMetadata) -> Bool {
        guard let tag = selectedTag else { return true }
        let normalized = tag.lowercased()
        return item.tagNames.contains { $0.lowercased() == normalized }
    }

    private func matchesSelectedSeries(_ item: BookMetadata) -> Bool {
        guard let series = selectedSeries else { return true }
        if series == SeriesView.noSeriesFilterKey {
            return item.series == nil || item.series?.isEmpty == true
        }
        let normalized = series.lowercased()
        return item.series?.contains(where: { $0.name.lowercased() == normalized }) ?? false
    }

    private func matchesSelectedCollection(_ item: BookMetadata) -> Bool {
        guard let collection = selectedCollection else { return true }
        let normalized = collection.lowercased()
        return item.collections?.contains(where: {
            $0.uuid?.lowercased() == normalized || $0.name.lowercased() == normalized
        }) ?? false
    }

    private func matchesSelectedAuthor(_ item: BookMetadata) -> Bool {
        guard let author = selectedAuthor else { return true }
        let normalized = author.lowercased()
        return item.authors?.contains(where: { $0.name?.lowercased() == normalized }) ?? false
    }

    private func matchesSelectedNarrator(_ item: BookMetadata) -> Bool {
        guard let narrator = selectedNarrator else { return true }
        if narrator == "Unknown Narrator" {
            guard let narrators = item.narrators, !narrators.isEmpty else { return true }
            return narrators.allSatisfy { narrator in
                guard let name = narrator.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
                return name.isEmpty
            }
        }
        let normalized = narrator.lowercased()
        return item.narrators?.contains(where: { $0.name?.lowercased() == normalized }) ?? false
    }

    private func matchesSelectedStatus(_ item: BookMetadata) -> Bool {
        guard let status = selectedStatus else { return true }
        guard let itemStatus = item.status?.name else { return false }
        return itemStatus.caseInsensitiveCompare(status) == .orderedSame
    }

    private func matchesSelectedLocation(_ item: BookMetadata) -> Bool {
        switch selectedLocation {
            case .all:
                return true
            case .downloaded:
                return hasAnyDownloadedCategory(for: item)
            case .serverOnly:
                return !hasAnyDownloadedCategory(for: item)
                    && !mediaViewModel.isLocalStandaloneBook(item.id)
            case .localFiles:
                return mediaViewModel.isLocalStandaloneBook(item.id)
        }
    }

    private func hasAnyDownloadedCategory(for item: BookMetadata) -> Bool {
        return mediaViewModel.isCategoryDownloaded(.ebook, for: item)
            || mediaViewModel.isCategoryDownloaded(.audio, for: item)
            || mediaViewModel.isCategoryDownloaded(.synced, for: item)
    }

    private func matchesSearchText(_ item: BookMetadata) -> Bool {
        guard searchText.count >= 2 else { return true }

        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return true }

        let title = item.title.lowercased()
        let authorNames = (item.authors ?? []).compactMap { $0.name?.lowercased() }
        let seriesNames = (item.series ?? []).compactMap { $0.name.lowercased() }

        for term in terms {
            let matchesTitle = title.contains(term)
            let matchesAuthor = authorNames.contains { $0.contains(term) }
            let matchesSeries = seriesNames.contains { $0.contains(term) }

            if !matchesTitle && !matchesAuthor && !matchesSeries {
                return false
            }
        }

        return true
    }

    private var availableTags: [String] {
        var unique: [String: String] = [:]
        for rawTag
            in catalogItemsForFilters
            .flatMap(\.tagNames)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
        {
            let key = rawTag.lowercased()
            if unique[key] == nil {
                unique[key] = rawTag
            }
        }
        return unique.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableStatuses: [String] {
        let statuses =
            catalogItemsForFilters
            .compactMap { metadata in
                metadata.status?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        var unique: [String: String] = [:]
        for status in statuses {
            let key = status.lowercased()
            if unique[key] == nil {
                unique[key] = status
            }
        }
        return unique.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableSeries: [String] {
        var unique: [String: String] = [:]
        for rawSeries
            in catalogItemsForFilters
            .compactMap(\.series)
            .flatMap({ $0 })
            .map({ $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
        {
            let key = rawSeries.lowercased()
            if unique[key] == nil {
                unique[key] = rawSeries
            }
        }
        return unique.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableAuthors: [String] {
        var unique: [String: String] = [:]
        for rawAuthor
            in catalogItemsForFilters
            .compactMap(\.authors)
            .flatMap({ $0 })
            .compactMap({ $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
        {
            let key = rawAuthor.lowercased()
            if unique[key] == nil {
                unique[key] = rawAuthor
            }
        }
        return unique.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var availableNarrators: [String] {
        var unique: [String: String] = [:]
        var hasUnknown = false
        for item in catalogItemsForFilters {
            if let narrators = item.narrators, !narrators.isEmpty {
                for narrator in narrators {
                    if let name = narrator.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                        let key = name.lowercased()
                        if unique[key] == nil {
                            unique[key] = name
                        }
                    } else {
                        hasUnknown = true
                    }
                }
            } else {
                hasUnknown = true
            }
        }
        var result = unique.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if hasUnknown {
            result.append("Unknown Narrator")
        }
        return result
    }

    private var filtersSummaryText: String {
        var parts: [String] = [selectedFormatFilter.shortLabel]
        if let status = selectedStatus {
            parts.append(status)
        }
        if let tag = selectedTag {
            parts.append(tag)
        }
        if let series = selectedSeries {
            parts.append(series)
        }
        if let author = selectedAuthor {
            parts.append(author)
        }
        if let narrator = selectedNarrator {
            parts.append(narrator)
        }
        if selectedLocation != .all {
            parts.append(selectedLocation.shortLabel)
        }
        return parts.joined(separator: " • ")
    }

    #if os(macOS)
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let visibleItems = displayItems
        guard !visibleItems.isEmpty else {
            clearSelection()
            return
        }

        guard
            let nextItem = MediaGridViewUtilities.nextSelectableItem(
                from: direction,
                in: visibleItems,
                currentItemID: activeInfoItem?.id,
                columnCount: max(lastKnownColumnCount, 1)
            )
        else {
            return
        }
        selectItem(nextItem, ensureVisible: true)
    }
    #endif

    enum SortOption: String, CaseIterable, Identifiable {
        case titleAZ
        case titleZA
        case authorAZ
        case authorZA
        case progressHighToLow
        case progressLowToHigh
        case recentlyRead
        case recentlyAdded
        case seriesPosition

        var id: String { rawValue }

        var label: String {
            switch self {
                case .titleAZ:
                    "Title A-Z"
                case .titleZA:
                    "Title Z-A"
                case .authorAZ:
                    "Author A-Z"
                case .authorZA:
                    "Author Z-A"
                case .progressHighToLow:
                    "Progress High-Low"
                case .progressLowToHigh:
                    "Progress Low-High"
                case .recentlyRead:
                    "Recently Read"
                case .recentlyAdded:
                    "Recently Added"
                case .seriesPosition:
                    "Series Position"
            }
        }

        var shortLabel: String {
            switch self {
                case .titleAZ:
                    "Title A-Z"
                case .titleZA:
                    "Title Z-A"
                case .authorAZ:
                    "Author A-Z"
                case .authorZA:
                    "Author Z-A"
                case .progressHighToLow:
                    "Progress High-Low"
                case .progressLowToHigh:
                    "Progress Low-High"
                case .recentlyRead:
                    "Recently Read"
                case .recentlyAdded:
                    "Recently Added"
                case .seriesPosition:
                    "Series Position"
            }
        }

        func comparison(_ lhs: BookMetadata, _ rhs: BookMetadata) -> ComparisonResult {
            switch self {
                case .titleAZ:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                case .titleZA:
                    return rhs.title.localizedCaseInsensitiveCompare(lhs.title)
                case .authorAZ:
                    let lhsAuthor = lhs.authors?.first?.name ?? ""
                    let rhsAuthor = rhs.authors?.first?.name ?? ""
                    let result = lhsAuthor.localizedCaseInsensitiveCompare(rhsAuthor)
                    if result == .orderedSame {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return result
                case .authorZA:
                    let lhsAuthor = lhs.authors?.first?.name ?? ""
                    let rhsAuthor = rhs.authors?.first?.name ?? ""
                    let result = rhsAuthor.localizedCaseInsensitiveCompare(lhsAuthor)
                    if result == .orderedSame {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return result
                case .progressHighToLow:
                    if lhs.progress == rhs.progress {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return lhs.progress > rhs.progress ? .orderedAscending : .orderedDescending
                case .progressLowToHigh:
                    if lhs.progress == rhs.progress {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return lhs.progress < rhs.progress ? .orderedAscending : .orderedDescending
                case .recentlyRead:
                    let lhsDate = lhs.position?.updatedAt ?? ""
                    let rhsDate = rhs.position?.updatedAt ?? ""
                    if lhsDate == rhsDate {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return lhsDate > rhsDate ? .orderedAscending : .orderedDescending
                case .recentlyAdded:
                    let lhsDate = lhs.createdAt ?? ""
                    let rhsDate = rhs.createdAt ?? ""
                    if lhsDate == rhsDate {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return lhsDate > rhsDate ? .orderedAscending : .orderedDescending
                case .seriesPosition:
                    let lhsSeriesName = lhs.series?.first?.name ?? ""
                    let rhsSeriesName = rhs.series?.first?.name ?? ""

                    if lhsSeriesName.isEmpty && rhsSeriesName.isEmpty {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    if lhsSeriesName.isEmpty {
                        return .orderedDescending
                    }
                    if rhsSeriesName.isEmpty {
                        return .orderedAscending
                    }

                    let seriesResult = lhsSeriesName.localizedCaseInsensitiveCompare(rhsSeriesName)
                    if seriesResult != .orderedSame {
                        return seriesResult
                    }

                    let lhsPosition = lhs.series?.first?.position ?? Int.max
                    let rhsPosition = rhs.series?.first?.position ?? Int.max
                    if lhsPosition == rhsPosition {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    }
                    return lhsPosition < rhsPosition ? .orderedAscending : .orderedDescending
            }
        }
    }

    enum FormatFilterOption: String, CaseIterable, Identifiable {
        case all
        case readaloud
        case ebook
        case audiobook
        case ebookOnly
        case audiobookOnly
        case missingReadaloud

        var id: String { rawValue }

        var label: String {
            switch self {
                case .all:
                    "All Titles"
                case .readaloud:
                    "Readaloud"
                case .ebook:
                    "Ebook Without Audio"
                case .audiobook:
                    "Audiobook"
                case .ebookOnly:
                    "Ebook Only"
                case .audiobookOnly:
                    "Audiobook Only"
                case .missingReadaloud:
                    "Missing Readaloud"
            }
        }

        var shortLabel: String {
            switch self {
                case .all:
                    "All"
                case .readaloud:
                    "Readaloud"
                case .ebook:
                    "Ebook"
                case .audiobook:
                    "Audiobook"
                case .ebookOnly:
                    "Ebook Only"
                case .audiobookOnly:
                    "Audiobook Only"
                case .missingReadaloud:
                    "Missing Readaloud"
            }
        }

        var includesAudiobookOnlyItems: Bool {
            switch self {
                case .all, .audiobook, .audiobookOnly:
                    true
                default:
                    false
            }
        }

        func matches(_ item: BookMetadata) -> Bool {
            switch self {
                case .all:
                    true
                case .readaloud:
                    item.hasAvailableReadaloud
                case .ebook:
                    item.hasAvailableEbook
                case .audiobook:
                    item.hasAvailableAudiobook || item.hasAvailableReadaloud
                case .ebookOnly:
                    item.isEbookOnly
                case .audiobookOnly:
                    item.isAudiobookOnly
                case .missingReadaloud:
                    item.isMissingReadaloud
            }
        }
    }

    enum LocationFilterOption: String, CaseIterable, Identifiable {
        case all
        case downloaded
        case serverOnly
        case localFiles

        var id: String { rawValue }

        var label: String {
            switch self {
                case .all:
                    "All Locations"
                case .downloaded:
                    "Downloaded"
                case .serverOnly:
                    "Server Only"
                case .localFiles:
                    "Local Files"
            }
        }

        var shortLabel: String {
            switch self {
                case .all:
                    "All"
                case .downloaded:
                    "Downloaded"
                case .serverOnly:
                    "Server Only"
                case .localFiles:
                    "Local Files"
            }
        }

        var iconName: String {
            switch self {
                case .all:
                    "square.grid.2x2"
                case .downloaded:
                    "play.circle"
                case .serverOnly:
                    "arrow.down.circle"
                case .localFiles:
                    "folder"
            }
        }
    }
}

#Preview("Ebooks") {
    MediaGridView(title: "Preview Library", mediaKind: .ebook)
}

#Preview("Audiobooks") {
    MediaGridView(
        title: "Preview Audiobooks",
        mediaKind: .audiobook,
        preferredTileWidth: 200,
        minimumTileWidth: 160,
    )
}
