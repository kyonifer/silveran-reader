import SwiftUI

#if os(macOS)
import AppKit
#endif

private enum HardcoverImportTarget: String, CaseIterable, Identifiable {
    case general
    case audiobook
    case ebook

    var id: String { rawValue }

    var title: String {
        switch self {
            case .general: return "General"
            case .audiobook: return "Audiobook Edition"
            case .ebook: return "Ebook Edition"
        }
    }

}

extension View {
    @ViewBuilder
    fileprivate func metadataImportCompactPopover() -> some View {
        #if os(iOS)
        self.presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}

private struct ReviewTagFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangeSubviews(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout (),
    ) {
        let arrangement = arrangeSubviews(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews,
        )
        for item in arrangement.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size),
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        let maxWidth = max(proposal.width ?? 0, 0)
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var items: [Arrangement.Item] = []

        for index in subviews.indices {
            let idealSize = subviews[index].sizeThatFits(.unspecified)
            let size = CGSize(
                width: maxWidth > 0 ? min(idealSize.width, maxWidth) : idealSize.width,
                height: idealSize.height,
            )
            if origin.x > 0, maxWidth > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            items.append(Arrangement.Item(index: index, origin: origin, size: size))
            usedWidth = max(usedWidth, origin.x + size.width)
            origin.x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return Arrangement(
            items: items,
            size: CGSize(width: maxWidth > 0 ? maxWidth : usedWidth, height: origin.y + rowHeight),
        )
    }

    private struct Arrangement {
        struct Item {
            let index: Int
            let origin: CGPoint
            let size: CGSize
        }

        let items: [Item]
        let size: CGSize
    }
}

extension View {
    fileprivate func reviewTagPill(isSelected: Bool = false) -> some View {
        self
            .font(.callout)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        isSelected ? Color.accentColor.opacity(0.86) : Color.secondary.opacity(0.08)
                    )
            }
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? Color.white.opacity(0.35) : Color.secondary.opacity(0.28),
                        lineWidth: isSelected ? 1.0 : 0.75,
                    )
            }
    }
}

private enum HardcoverImportUseDestination: String, CaseIterable, Identifiable {
    case none
    case general
    case audiobook
    case ebook

    var id: String { rawValue }

    var target: HardcoverImportTarget? {
        switch self {
            case .none: return nil
            case .general: return .general
            case .audiobook: return .audiobook
            case .ebook: return .ebook
        }
    }
}

private enum HardcoverEditionUseDestination: String, CaseIterable, Identifiable, Hashable {
    case none
    case audiobook
    case ebook

    var id: String { rawValue }

    var title: String {
        switch self {
            case .none: return "None"
            case .audiobook: return "Audiobook Edition"
            case .ebook: return "Ebook Edition"
        }
    }
}

private enum HardcoverImportStep {
    case search
    case review
}

private enum HardcoverReviewTagCategory: String, CaseIterable, Identifiable {
    case genre
    case mood
    case contentWarning

    var id: String { rawValue }

    var title: String {
        switch self {
            case .genre: return "Genre"
            case .mood: return "Mood"
            case .contentWarning: return "Content Warning"
        }
    }

    func contains(_ category: String?) -> Bool {
        let normalized = (category ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch self {
            case .genre:
                return normalized == "genre" || normalized == "genres"
            case .mood:
                return normalized == "mood" || normalized == "moods"
            case .contentWarning:
                return normalized == "content warning" || normalized == "content warnings"
                    || normalized == "content_warning" || normalized == "content-warnings"
        }
    }
}

private enum HardcoverReviewTagSort {
    case popularity
    case alphabetical
}

private let collapsedReviewTagAreaHeight: CGFloat = 126

private struct HardcoverImportAssignment {
    let resultId: Int
    let editionId: Int?
    let details: HardcoverBookDetails
}

struct HardcoverImportView: View {
    @State private var viewModel = HardcoverImportViewModel()
    @State private var selectedTarget: HardcoverImportTarget = .general
    @State private var generalAssignment: HardcoverImportAssignment?
    @State private var ebookAssignment: HardcoverImportAssignment?
    @State private var step: HardcoverImportStep = .search
    @State private var reviewFields: Set<String> = []
    @State private var expandedReviewRowId: String?
    @State private var tokenHelpPresented = false
    @State private var highlightedEditionId: Int?
    @State private var noChangePopoverRowId: String?
    @State private var selectedReviewTagCategory: HardcoverReviewTagCategory = .genre
    @State private var reviewTagSort: HardcoverReviewTagSort = .popularity
    @State private var reviewTagShowsCounts = false
    let bookTitle: String
    let bookAuthor: String?
    let currentBook: MetadataEditorViewModel.EditableBook
    let onImport:
        ([MetadataEditorViewModel.HardcoverImportSource: HardcoverBookDetails], Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompactIOS: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if step == .search {
                tokenSection
                Divider()
                searchSection
                Divider()
                resultsList
            } else {
                reviewSection
            }
            Divider()
            bottomBar
        }
        .frame(width: isCompactIOS ? nil : 920, height: isCompactIOS ? nil : 640)
        .frame(maxWidth: isCompactIOS ? .infinity : nil, maxHeight: isCompactIOS ? .infinity : nil)
        .task {
            viewModel.loadFieldSelection()
            await viewModel.loadToken()
            viewModel.prefill(title: bookTitle, author: bookAuthor)
            if viewModel.hasToken {
                await viewModel.search()
            }
        }
        .onChange(of: selectedTarget) { _, _ in
            reviewFields.removeAll()
            expandedReviewRowId = nil
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step == .search ? "Import Hardcover Metadata" : "Review Hardcover Import")
                .font(.title3.weight(.semibold))
            Text(
                step == .search
                    ? "Choose which Hardcover result to use for General details or for an edition."
                    : "Click the arrows for incoming Hardcover values you want to copy into the editor."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var selectedTargetImports:
        [MetadataEditorViewModel.HardcoverImportSource: HardcoverBookDetails]
    {
        var imports: [MetadataEditorViewModel.HardcoverImportSource: HardcoverBookDetails] = [:]
        if let details = generalAssignment?.details ?? ebookAssignment?.details {
            imports[.text] = details
        }
        if let details = viewModel.selectedImports[.audiobook] {
            imports[.audiobook] = details
        }
        return imports
    }

    private var selectedTargetDetails: HardcoverBookDetails? {
        generalAssignment?.details
            ?? ebookAssignment?.details
            ?? viewModel.selectedImports[.audiobook]
    }

    private var hasReviewSelection: Bool {
        generalAssignment != nil
            || ebookAssignment != nil
            || viewModel.selectedImports[.audiobook] != nil
    }

    // MARK: - Token

    @ViewBuilder
    private var tokenSection: some View {
        Group {
            if isCompactIOS {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(viewModel.hasToken ? .green : .secondary)
                        Text("Hardcover credentials")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if !viewModel.hasToken || viewModel.isEditingToken {
                            tokenHelpButton
                        }
                    }

                    if viewModel.hasToken && !viewModel.isEditingToken {
                        HStack {
                            Text("Token saved")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Change") {
                                viewModel.isEditingToken = true
                            }
                            .font(.callout)
                            Button("Clear") {
                                Task { await viewModel.clearToken() }
                            }
                            .font(.callout)
                            .foregroundStyle(.red)
                        }
                    } else {
                        SecureField("Hardcover API Token", text: $viewModel.tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await viewModel.saveToken() }
                            }
                        HStack {
                            Button("Save") {
                                Task { await viewModel.saveToken() }
                            }
                            .disabled(
                                viewModel.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                            if viewModel.hasToken {
                                Button("Cancel") {
                                    viewModel.isEditingToken = false
                                    viewModel.tokenInput = ""
                                }
                            } else {
                                Text("You need a Hardcover API key to continue.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(viewModel.hasToken ? .green : .secondary)
                    Text("Hardcover credentials")
                        .font(.callout.weight(.semibold))

                    if viewModel.hasToken && !viewModel.isEditingToken {
                        Text("Token saved")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change") {
                            viewModel.isEditingToken = true
                        }
                        .font(.callout)
                        Button("Clear") {
                            Task { await viewModel.clearToken() }
                        }
                        .font(.callout)
                        .foregroundStyle(.red)
                    } else {
                        SecureField("Hardcover API Token", text: $viewModel.tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await viewModel.saveToken() }
                            }
                        Button("Save") {
                            Task { await viewModel.saveToken() }
                        }
                        .disabled(
                            viewModel.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                        if viewModel.hasToken {
                            Button("Cancel") {
                                viewModel.isEditingToken = false
                                viewModel.tokenInput = ""
                            }
                        } else {
                            HStack(spacing: 4) {
                                Text("You need a Hardcover API key to continue.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                tokenHelpButton
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(viewModel.hasToken ? Color.clear : .yellow.opacity(0.05))
    }

    private var tokenHelpButton: some View {
        Button {
            tokenHelpPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("How to get a Hardcover API token")
        .popover(isPresented: $tokenHelpPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hardcover API Token")
                    .font(.headline)
                Text(
                    "Create or copy a token from your Hardcover account API settings, then paste the token here. You can paste either the raw token or a Bearer token."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Link(
                    "Open Hardcover API settings",
                    destination: URL(string: "https://hardcover.app/account/api")!,
                )
                .font(.callout)
            }
            .padding()
            .frame(width: 320)
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchSection: some View {
        HStack(spacing: 8) {
            TextField("Search Hardcover...", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.search() }
                }
            Button("Search") {
                Task { await viewModel.search() }
            }
            .disabled(
                viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isSearching || !viewModel.hasToken
            )
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: - Results List

    @State private var expandedResultIds: Set<Int> = []
    @State private var infoPopoverId: Int?
    @State private var filterPopoverId: Int?
    @AppStorage("hardcoverImport.filterLanguage") private var editionFilterLanguage: String?
    @AppStorage("hardcoverImport.filterFormat") private var editionFilterFormat: String?
    @State private var editionPreviewId: Int?

    @ViewBuilder
    private var resultsList: some View {
        List {
            ForEach(viewModel.searchResults) { result in
                searchResultRow(result: result)
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.searchResults.isEmpty && !viewModel.isSearching {
                if !viewModel.hasToken {
                    ContentUnavailableView(
                        "Enter API Token",
                        systemImage: "key",
                        description: Text("Enter your Hardcover API token above to search"),
                    )
                } else if !viewModel.hasSearched {
                    ContentUnavailableView(
                        "Search Hardcover",
                        systemImage: "magnifyingglass",
                        description: Text("Press Search or Enter to find books"),
                    )
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "book.closed",
                        description: Text("Try a different search term"),
                    )
                }
            }
        }
    }

    // MARK: - Search Result Row

    @ViewBuilder
    private func searchResultRow(result: HardcoverSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            searchResultHeader(result: result)

            if expandedResultIds.contains(result.id),
                let details = viewModel.infoDetails[result.id]
            {
                if isCompactIOS {
                    ScrollView(.horizontal, showsIndicators: true) {
                        editionsList(details: details, result: result)
                            .frame(minWidth: 720, alignment: .leading)
                    }
                } else {
                    editionsList(details: details, result: result)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultHeader(result: HardcoverSearchResult) -> some View {
        HStack {
            chevronButton(result: result)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                    .font(.body)
                if !result.authorNames.isEmpty {
                    Text(result.authorNames.joined(separator: ", "))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let year = result.releaseYear {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            resultActionButtons(result: result)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !expandedResultIds.contains(result.id) {
                expandedResultIds.insert(result.id)
            }
            Task { await assignResult(result, to: .general) }
        }
        .padding(.vertical, 2)
        .background(
            resultUsesGeneral(result)
                ? Color.accentColor.opacity(0.2) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func chevronButton(result: HardcoverSearchResult) -> some View {
        Button(action: {
            if expandedResultIds.contains(result.id) {
                expandedResultIds.remove(result.id)
            } else {
                expandedResultIds.insert(result.id)
                Task { await viewModel.fetchInfo(for: result) }
            }
        }) {
            if viewModel.infoFetchingId == result.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12)
            } else {
                Image(
                    systemName: expandedResultIds.contains(result.id)
                        ? "chevron.down" : "chevron.right"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func resultActionButtons(result: HardcoverSearchResult) -> some View {
        if expandedResultIds.contains(result.id) {
            let hasFilter = editionFilterLanguage != nil || editionFilterFormat != nil
            Button(action: {
                filterPopoverId = filterPopoverId == result.id ? nil : result.id
            }) {
                Image(
                    systemName: hasFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .foregroundStyle(hasFilter ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .popover(
                isPresented: Binding(
                    get: { filterPopoverId == result.id },
                    set: { if !$0 { filterPopoverId = nil } },
                )
            ) {
                editionFilterPopover(for: result.id)
            }
        }

        Button(action: {
            infoPopoverId = infoPopoverId == result.id ? nil : result.id
            Task { await viewModel.fetchInfo(for: result) }
        }) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .popover(
            isPresented: Binding(
                get: { infoPopoverId == result.id },
                set: { if !$0 { infoPopoverId = nil } },
            )
        ) {
            bookInfoPopover(for: result.id)
        }

        if viewModel.selectedResult?.id == result.id && viewModel.isFetching {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Edition Filter

    private static let digitalNormalized: Set<String> = [
        "Ebook", "Kindle", "Audible", "Audiobook",
    ]
    private static let physicalNormalized: Set<String> = [
        "Hardcover", "Paperback", "Mass Market Paperback",
    ]
    private static let ebookNormalized: Set<String> = [
        "Ebook", "Kindle",
    ]
    private static let audiobookNormalized: Set<String> = [
        "Audible", "Audiobook",
    ]

    private func filteredEditions(_ editions: [HardcoverEditionInfo]) -> [HardcoverEditionInfo] {
        editions.filter { edition in
            if let lang = editionFilterLanguage {
                guard edition.language?.lowercased() == lang.lowercased() else { return false }
            }
            if let fmt = editionFilterFormat {
                let normalized = normalizedFormat(edition.format)
                switch fmt {
                    case "digital":
                        guard Self.digitalNormalized.contains(normalized) else { return false }
                    case "physical":
                        guard Self.physicalNormalized.contains(normalized) else { return false }
                    case "ebook":
                        guard Self.ebookNormalized.contains(normalized) else { return false }
                    case "audiobook":
                        guard Self.audiobookNormalized.contains(normalized) else { return false }
                    default:
                        guard normalized == fmt else { return false }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func editionFilterPopover(for bookId: Int) -> some View {
        let editions = viewModel.infoDetails[bookId]?.editions ?? []
        let languages = Array(Set(editions.compactMap(\.language))).sorted()
        let formats = Array(Set(editions.map { normalizedFormat($0.format) })).sorted()

        VStack(alignment: .leading, spacing: 10) {
            Text("Filter Editions").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Language").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $editionFilterLanguage) {
                    Text("All").tag(String?.none)
                    ForEach(languages, id: \.self) { lang in
                        Text(lang).tag(Optional(lang))
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Format").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $editionFilterFormat) {
                    Text("All").tag(String?.none)
                    Divider()
                    Text("Digital Only").tag(Optional("digital"))
                    Text("Physical Only").tag(Optional("physical"))
                    Text("Ebook Only").tag(Optional("ebook"))
                    Text("Audiobook Only").tag(Optional("audiobook"))
                    Divider()
                    ForEach(formats, id: \.self) { fmt in
                        Text(fmt).tag(Optional(fmt))
                    }
                }
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Clear Filters") {
                    editionFilterLanguage = nil
                    editionFilterFormat = nil
                }
                .disabled(editionFilterLanguage == nil && editionFilterFormat == nil)
                .font(.callout)
            }
        }
        .padding()
        .frame(width: 220)
    }

    // MARK: - Editions List

    @ViewBuilder
    private func editionsList(
        details: HardcoverBookDetails,
        result: HardcoverSearchResult,
    ) -> some View {
        let filtered = filteredEditions(details.editions)
        VStack(alignment: .leading, spacing: 2) {
            editionHeaderRow
            ForEach(filtered) { edition in
                HStack(spacing: 4) {
                    Spacer().frame(width: 16)
                    if let imageUrl = edition.imageUrl, let url = URL(string: imageUrl) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 20, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    } else {
                        Color.clear.frame(width: 20, height: 28)
                    }
                    Image(systemName: editionIcon(edition.format))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(normalizedFormat(edition.format))
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                        .lineLimit(1)
                    Text(edition.language ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .center)
                        .lineLimit(1)
                    Text(countryAbbreviation(edition.country) ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .center)
                        .lineLimit(1)
                    Text(editionDateLabel(edition))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .center)
                        .lineLimit(1)
                    Text(editionLengthLabel(edition))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .center)
                    Text(edition.isbn13 ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 105, alignment: .center)
                    if !edition.narrators.isEmpty {
                        Text(edition.narrators.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    columnSeparator
                    Picker(
                        "Use for Edition",
                        selection: Binding(
                            get: { editionDestination(edition) },
                            set: { destination in
                                assignEditionUse(
                                    edition,
                                    bookId: result.id,
                                    parentDetails: details,
                                    to: destination,
                                )
                            },
                        ),
                    ) {
                        ForEach(HardcoverEditionUseDestination.allCases) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 148)
                    .help("Choose which edition this Hardcover entry should import into")
                    Button(action: {
                        editionPreviewId = editionPreviewId == edition.id ? nil : edition.id
                    }) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .popover(
                        isPresented: Binding(
                            get: { editionPreviewId == edition.id },
                            set: { if !$0 { editionPreviewId = nil } },
                        )
                    ) {
                        editionPreviewPopover(
                            edition: edition,
                            bookDetails: details,
                        )
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .background(
                    highlightedEditionId == edition.id
                        ? Color.accentColor.opacity(0.2) : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture {
                    highlightedEditionId = edition.id
                    selectWorkFromEditionRow(bookId: result.id, details: details)
                }
            }
        }
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    private var editionHeaderRow: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 16)
            Text("")
                .frame(width: 20)
            Text("")
                .frame(width: 14)
            Text("Format")
                .frame(width: 80, alignment: .leading)
            Text("Language")
                .frame(width: 55, alignment: .center)
            Text("Country")
                .frame(width: 48, alignment: .center)
            Text("Pub Date")
                .frame(width: 78, alignment: .center)
            Text("Length")
                .frame(width: 50, alignment: .center)
            Text("ISBN")
                .frame(width: 105, alignment: .center)
            Text("Narrators")
                .frame(maxWidth: .infinity, alignment: .leading)
            columnSeparator
            Text("Use for Edition...")
                .frame(width: 148)
            Text("")
                .frame(width: 18)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private var columnSeparator: some View {
        Rectangle()
            .fill(.separator.opacity(0.7))
            .frame(width: 1, height: 28)
            .frame(width: 9)
    }

    private func editionDestination(_ edition: HardcoverEditionInfo)
        -> HardcoverEditionUseDestination
    {
        if viewModel.selectedAudiobookEditionId == edition.id {
            return .audiobook
        }
        if ebookAssignment?.editionId == edition.id {
            return .ebook
        }
        return .none
    }

    private func resultUsesGeneral(_ result: HardcoverSearchResult) -> Bool {
        generalAssignment?.resultId == result.id && generalAssignment?.editionId == nil
    }

    private func assignResult(
        _ result: HardcoverSearchResult,
        to destination: HardcoverImportUseDestination,
    ) async {
        guard let target = destination.target else {
            if generalAssignment?.resultId == result.id && generalAssignment?.editionId == nil {
                generalAssignment = nil
            }
            return
        }
        selectedTarget = target
        switch target {
            case .general:
                await viewModel.fetchInfo(for: result)
                if let details = viewModel.infoDetails[result.id] {
                    generalAssignment = HardcoverImportAssignment(
                        resultId: result.id,
                        editionId: nil,
                        details: details,
                    )
                }
            case .ebook:
                await viewModel.fetchInfo(for: result)
                if let details = viewModel.infoDetails[result.id] {
                    ebookAssignment = HardcoverImportAssignment(
                        resultId: result.id,
                        editionId: nil,
                        details: details,
                    )
                }
            case .audiobook:
                await viewModel.selectResult(result)
                viewModel.useFetchedDetailsForAudiobook()
        }
    }

    private func assignEdition(
        _ edition: HardcoverEditionInfo,
        bookId: Int,
        parentDetails: HardcoverBookDetails,
        to destination: HardcoverEditionUseDestination,
    ) {
        viewModel.infoDetails[bookId] = parentDetails
        highlightedEditionId = edition.id
        switch destination {
            case .none:
                if generalAssignment?.editionId == edition.id {
                    generalAssignment = nil
                }
                if ebookAssignment?.editionId == edition.id {
                    ebookAssignment = nil
                }
                if viewModel.selectedAudiobookEditionId == edition.id {
                    viewModel.clearAudiobookSelection()
                }
                return
            case .ebook:
                selectedTarget = .ebook
                if let details = viewModel.detailsForEdition(edition, bookId: bookId) {
                    ebookAssignment = HardcoverImportAssignment(
                        resultId: bookId,
                        editionId: edition.id,
                        details: details,
                    )
                }
            case .audiobook:
                selectedTarget = .audiobook
                viewModel.selectEdition(edition, bookId: bookId, source: .audiobook)
        }
    }

    private func selectWorkFromEditionRow(bookId: Int, details: HardcoverBookDetails) {
        viewModel.infoDetails[bookId] = details
        generalAssignment = HardcoverImportAssignment(
            resultId: bookId,
            editionId: nil,
            details: details,
        )
        selectedTarget = .general
    }

    private func assignEditionUse(
        _ edition: HardcoverEditionInfo,
        bookId: Int,
        parentDetails: HardcoverBookDetails,
        to destination: HardcoverEditionUseDestination,
    ) {
        switch destination {
            case .none:
                assignEdition(edition, bookId: bookId, parentDetails: parentDetails, to: .none)
            case .ebook:
                assignEdition(edition, bookId: bookId, parentDetails: parentDetails, to: .ebook)
            case .audiobook:
                assignEdition(
                    edition,
                    bookId: bookId,
                    parentDetails: parentDetails,
                    to: .audiobook,
                )
        }
    }

    @ViewBuilder
    private func editionPreviewPopover(
        edition: HardcoverEditionInfo,
        bookDetails: HardcoverBookDetails,
    ) -> some View {
        let narrators = edition.narrators.isEmpty ? bookDetails.narrators : edition.narrators
        let creators =
            edition.otherContributors.isEmpty
            ? bookDetails.creators : edition.otherContributors
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(edition.editionInfo ?? edition.format).font(.headline)

                editionPreviewFields(edition: edition, bookDetails: bookDetails)
                editionPreviewPeople(
                    bookDetails: bookDetails,
                    narrators: narrators,
                    creators: creators,
                )
                editionPreviewCollections(bookDetails: bookDetails)
            }
            .padding()
        }
        .frame(width: 380, height: 320)
    }

    @ViewBuilder
    private func editionPreviewFields(
        edition: HardcoverEditionInfo,
        bookDetails: HardcoverBookDetails,
    ) -> some View {
        row("Title", edition.title ?? bookDetails.title)
        row("Subtitle", edition.subtitle ?? bookDetails.subtitle)
        row("Language", edition.language ?? bookDetails.language)
        row("Country", edition.country)
        row("Release Date", edition.releaseDate ?? bookDetails.releaseDate)
        row("Publisher", edition.publisher)
        row("Pages", edition.pages.map { "\($0)" })
        if let secs = edition.audioSeconds, secs > 0 {
            let hrs = secs / 3600
            let mins = (secs % 3600) / 60
            row("Audio Length", "\(hrs)h \(mins)m")
        }
        row("ISBN-13", edition.isbn13)
        row("ISBN-10", edition.isbn10)
        row("ASIN", edition.asin)
    }

    @ViewBuilder
    private func editionPreviewPeople(
        bookDetails: HardcoverBookDetails,
        narrators: [String],
        creators: [(name: String, role: String)],
    ) -> some View {
        if !bookDetails.authors.isEmpty {
            row("Authors", bookDetails.authors.joined(separator: ", "))
        }
        if !narrators.isEmpty {
            row("Narrators", narrators.joined(separator: ", "))
        }
        if !creators.isEmpty {
            row(
                "Creators",
                creators.map { "\($0.name) (\($0.role))" }.joined(separator: ", "),
            )
        }
    }

    @ViewBuilder
    private func editionPreviewCollections(bookDetails: HardcoverBookDetails) -> some View {
        if !bookDetails.series.isEmpty {
            row(
                "Series",
                bookDetails.series.map { s in
                    s.position != nil ? "\(s.name) #\(s.position!.formatted())" : s.name
                }.joined(separator: ", "),
            )
        }
        if !bookDetails.tags.isEmpty {
            row("Tags", bookDetails.tags.prefix(10).map(\.name).joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .lineLimit(2)
            }
            .font(.callout)
        }
    }

    private func countryAbbreviation(_ name: String?) -> String? {
        guard let name else { return nil }
        let target = name.lowercased()
        let english = Locale(identifier: "en")
        for code in Locale.isoRegionCodes {
            if let localized = english.localizedString(forRegionCode: code)?.lowercased(),
                localized == target || target.contains(localized) || localized.contains(target)
            {
                return code
            }
        }
        return String(name.prefix(3))
    }

    private static let formatNormalization: [String: String] = [
        "ebook": "Ebook",
        "e-book": "Ebook",
        "kindle": "Kindle",
        "epub3": "Ebook",
        "audible": "Audible",
        "audiobook": "Audiobook",
        "unabridged audiobook": "Audiobook",
        "hardcover": "Hardcover",
        "paperback": "Paperback",
        "mass market paperback": "Mass Market Paperback",
    ]

    private func normalizedFormat(_ format: String) -> String {
        Self.formatNormalization[format.lowercased()]
            ?? {
                guard let first = format.first else { return format }
                return String(first).uppercased() + format.dropFirst()
            }()
    }

    private func editionLengthLabel(_ edition: HardcoverEditionInfo) -> String {
        if let secs = edition.audioSeconds, secs > 0 {
            let hrs = secs / 3600
            let mins = (secs % 3600) / 60
            return "\(hrs)h \(mins)m"
        }
        if let pages = edition.pages {
            return "\(pages) pp"
        }
        return ""
    }

    private func editionDateLabel(_ edition: HardcoverEditionInfo) -> String {
        guard let raw = edition.releaseDate, !raw.isEmpty else { return "" }
        return MetadataEditorViewModel.EditableBook.dateOnly(raw) ?? raw
    }

    private func editionIcon(_ format: String) -> String {
        switch format.lowercased() {
            case "audiobook", "audio": return "headphones"
            case "ebook", "kindle", "digital": return "tablet.landscape"
            case "hardcover": return "book.closed.fill"
            case "paperback": return "book.closed"
            default: return "book"
        }
    }

    private func hardcoverBookLink(_ details: HardcoverBookDetails) -> URL? {
        if let slug = details.slug, !slug.isEmpty {
            return URL(string: "https://hardcover.app/books/\(slug)")
        }
        if let id = details.id {
            return URL(string: "https://hardcover.app/books/\(id)")
        }
        return nil
    }

    private func hardcoverSlugLink(_ slug: String?, url: URL) -> some View {
        HStack(spacing: 6) {
            Link(slug ?? "Open on Hardcover", destination: url)
                .font(.callout)
            Button {
                copyToPasteboard(url.absoluteString)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy Hardcover URL")
        }
    }

    private func copyToPasteboard(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    // MARK: - Book Info Popover

    @ViewBuilder
    private func bookInfoPopover(for bookId: Int) -> some View {
        if let details = viewModel.infoDetails[bookId] {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = details.title {
                        Text(title).font(.headline)
                    }
                    if let link = hardcoverBookLink(details) {
                        hardcoverSlugLink(details.slug, url: link)
                    }
                    if let subtitle = details.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !details.authors.isEmpty {
                        LabeledContent("Authors") {
                            Text(details.authors.joined(separator: ", "))
                        }
                    }
                    if !details.narrators.isEmpty {
                        LabeledContent("Narrators") {
                            Text(details.narrators.joined(separator: ", "))
                        }
                    }
                    if !details.series.isEmpty {
                        LabeledContent("Series") {
                            VStack(alignment: .trailing) {
                                ForEach(details.series, id: \.name) { s in
                                    Text(
                                        s.position != nil
                                            ? "\(s.name) #\(s.position!.formatted())"
                                            : s.name
                                    )
                                }
                            }
                        }
                    }
                    if let date = details.releaseDate, !date.isEmpty {
                        LabeledContent("Release Date", value: date)
                    }
                    if let rating = details.rating {
                        LabeledContent("Rating", value: String(format: "%.1f", rating))
                    }
                    if !details.tags.isEmpty {
                        LabeledContent("Tags") {
                            Text(details.tags.prefix(10).map(\.name).joined(separator: ", "))
                        }
                    }

                    let isbns = details.editions.compactMap { ed -> String? in
                        guard let isbn = ed.isbn13 else { return nil }
                        return "\(ed.format): \(isbn)"
                    }
                    if !isbns.isEmpty {
                        LabeledContent("ISBNs") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(isbns.prefix(6), id: \.self) { isbn in
                                    Text(isbn).font(.caption)
                                }
                                if isbns.count > 6 {
                                    Text("+\(isbns.count - 6) more")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if let desc = details.description, !desc.isEmpty {
                        Divider()
                        Text(desc)
                            .font(.callout)
                            .lineLimit(10)
                    }
                }
                .padding()
            }
            .frame(width: 380, height: 320)
        } else {
            ProgressView()
                .padding()
                .frame(width: 150, height: 60)
        }
    }

    // MARK: - Review

    private struct ReviewRow: Identifiable {
        let id: String
        let label: String
        let current: String
        let incoming: String
        let currentComparison: String
        let incomingComparison: String
        let details: HardcoverBookDetails

        var differs: Bool {
            currentComparison != incomingComparison
        }
    }

    private struct ReviewRowSection: Identifiable {
        let id: String
        let title: String
        let rows: [ReviewRow]
    }

    @ViewBuilder
    private var reviewSection: some View {
        if let details = selectedTargetDetails {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Current Metadata")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("")
                                .frame(width: 34)
                            Text("Hardcover Import")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.secondary)

                        ForEach(reviewSections(for: details)) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .padding(.top, 8)

                                ForEach(section.rows) { row in
                                    if row.id == "tags" {
                                        reviewTagsRow(row: row)
                                    } else {
                                        reviewRow(row)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            ContentUnavailableView(
                "No Import Selection",
                systemImage: "book.closed",
                description: Text(
                    "Go back and select a Hardcover result for \(selectedTarget.title)."
                ),
            )
        }
    }

    private func reviewRow(_ row: ReviewRow) -> some View {
        let isExpanded = expandedReviewRowId == row.id

        return HStack(alignment: .center, spacing: 12) {
            reviewColumn(
                label: row.label,
                value: row.current,
                isExpanded: isExpanded,
                help: isExpanded ? "Collapse \(row.label)" : "Show full \(row.label)",
            ) {
                expandedReviewRowId = isExpanded ? nil : row.id
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                guard row.differs else {
                    noChangePopoverRowId = row.id
                    return
                }
                if reviewFields.contains(row.id) {
                    reviewFields.remove(row.id)
                } else {
                    reviewFields.insert(row.id)
                }
            } label: {
                Image(
                    systemName: reviewFields.contains(row.id)
                        ? "arrow.left.circle.fill" : "arrow.left.circle"
                )
                .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.differs ? Color.accentColor : Color.secondary.opacity(0.45))
            .help(
                row.differs
                    ? "Copy Hardcover \(row.label) into current metadata" : "Already matches"
            )
            .popover(
                isPresented: Binding(
                    get: { noChangePopoverRowId == row.id },
                    set: { if !$0 { noChangePopoverRowId = nil } },
                )
            ) {
                Text("No changes")
                    .font(.callout)
                    .padding()
                    .metadataImportCompactPopover()
            }
            .frame(width: 34)

            reviewColumn(
                label: row.label,
                value: row.incoming,
                isExpanded: isExpanded,
                help: isExpanded ? "Collapse \(row.label)" : "Show full \(row.label)",
            ) {
                expandedReviewRowId = isExpanded ? nil : row.id
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            reviewExpansionButton(
                rowId: row.id,
                isExpanded: isExpanded,
                label: row.label,
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(reviewFields.contains(row.id) ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }

    private func reviewTagsRow(row: ReviewRow) -> some View {
        let isExpanded = expandedReviewRowId == row.id
        let incomingTags = sortedReviewTags(
            row.details.tags.filter { selectedReviewTagCategory.contains($0.category) }
        )
        let selectedTagCount = selectedReviewTagCount
        let hasSelectedTags = selectedTagCount > 0
        let importableTagIds = reviewImportableTagIds(for: row.details)
        let hasImportableTags = !importableTagIds.isEmpty

        return Group {
            if isCompactIOS {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        reviewTagsHeader(
                            title: "Current Tags",
                            showsSortControls: false,
                            selectedCount: nil,
                        )

                        reviewExpansionButton(
                            rowId: row.id,
                            isExpanded: isExpanded,
                            label: "Tags",
                        )
                    }
                    reviewCurrentTagPills(isExpanded: isExpanded)

                    reviewTagsImportButton(
                        row: row,
                        importableTagIds: importableTagIds,
                        hasImportableTags: hasImportableTags,
                        hasSelectedTags: hasSelectedTags,
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)

                    reviewTagsHeader(
                        title: "Hardcover Tags",
                        showsSortControls: true,
                        selectedCount: selectedTagCount,
                    )
                    Picker("", selection: $selectedReviewTagCategory) {
                        ForEach(HardcoverReviewTagCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if incomingTags.isEmpty {
                        Text(
                            "No \(selectedReviewTagCategory.title.lowercased()) tags from Hardcover."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: isExpanded ? 0 : collapsedReviewTagAreaHeight,
                            alignment: .topLeading,
                        )
                    } else {
                        reviewIncomingTagPills(tags: incomingTags, isExpanded: isExpanded)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ZStack {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            reviewTagsHeader(
                                title: "Tags",
                                showsSortControls: false,
                                selectedCount: nil,
                            )
                            reviewCurrentTagPills(isExpanded: isExpanded)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        Color.clear
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 8) {
                            reviewTagsHeader(
                                title: "Tags",
                                showsSortControls: true,
                                selectedCount: selectedTagCount,
                            )
                            Picker("", selection: $selectedReviewTagCategory) {
                                ForEach(HardcoverReviewTagCategory.allCases) { category in
                                    Text(category.title).tag(category)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if incomingTags.isEmpty {
                                Text(
                                    "No \(selectedReviewTagCategory.title.lowercased()) tags from Hardcover."
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: isExpanded ? 0 : collapsedReviewTagAreaHeight,
                                    alignment: .topLeading,
                                )
                            } else {
                                reviewIncomingTagPills(tags: incomingTags, isExpanded: isExpanded)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    reviewExpansionButton(
                        rowId: row.id,
                        isExpanded: isExpanded,
                        label: "Tags",
                    )
                    .frame(width: 24, alignment: .trailing)

                    reviewTagsImportButton(
                        row: row,
                        importableTagIds: importableTagIds,
                        hasImportableTags: hasImportableTags,
                        hasSelectedTags: hasSelectedTags,
                    )
                    .frame(width: 34)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hasSelectedTags ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }

    private func reviewTagsImportButton(
        row: ReviewRow,
        importableTagIds: Set<String>,
        hasImportableTags: Bool,
        hasSelectedTags: Bool,
    ) -> some View {
        let iconName =
            !reviewFields.isDisjoint(with: importableTagIds)
            ? (isCompactIOS ? "arrow.up.circle.fill" : "arrow.left.circle.fill")
            : (isCompactIOS ? "arrow.up.circle" : "arrow.left.circle")

        return Button {
            guard hasImportableTags else {
                noChangePopoverRowId = row.id
                return
            }
            if hasSelectedTags {
                clearSelectedReviewTags()
            } else {
                reviewFields.formUnion(importableTagIds)
            }
        } label: {
            Image(systemName: iconName)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hasImportableTags ? Color.accentColor : Color.secondary.opacity(0.45))
        .help(hasImportableTags ? "Import all available Hardcover tags" : "No tag changes")
        .popover(
            isPresented: Binding(
                get: { noChangePopoverRowId == row.id },
                set: { if !$0 { noChangePopoverRowId = nil } },
            )
        ) {
            Text("No tag changes")
                .font(.callout)
                .padding()
                .metadataImportCompactPopover()
        }
    }

    private func reviewTagsHeader(
        title: String,
        showsSortControls: Bool,
        selectedCount: Int?,
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let selectedCount, selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    clearSelectedReviewTags()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear selected tags")
            }
            if showsSortControls {
                Menu {
                    Picker("Sort", selection: $reviewTagSort) {
                        Text("Popularity").tag(HardcoverReviewTagSort.popularity)
                        Text("Alphabetical").tag(HardcoverReviewTagSort.alphabetical)
                    }
                    Toggle("Show popularity counts", isOn: $reviewTagShowsCounts)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .help("Tag display options")
            }
        }
    }

    private func clearSelectedReviewTags() {
        reviewFields = reviewFields.filter { !$0.hasPrefix("tags:") }
    }

    @ViewBuilder
    private func reviewCurrentTagPills(isExpanded: Bool) -> some View {
        let tags = currentBook.tags
        if tags.isEmpty {
            Text("(empty)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ReviewTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(
                    tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                    id: \.self,
                ) { tag in
                    Text(tag)
                        .reviewTagPill()
                }
            }
            .frame(
                minHeight: isExpanded ? 0 : collapsedReviewTagAreaHeight,
                maxHeight: isExpanded ? nil : collapsedReviewTagAreaHeight,
                alignment: .top,
            )
            .clipped()
        }
    }

    private func reviewIncomingTagPills(tags: [HardcoverTagInfo], isExpanded: Bool) -> some View {
        ReviewTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(tags, id: \.name) { tag in
                reviewIncomingTagPill(tag)
            }
        }
        .frame(
            minHeight: isExpanded ? 0 : collapsedReviewTagAreaHeight,
            maxHeight: isExpanded ? nil : collapsedReviewTagAreaHeight,
            alignment: .top,
        )
        .clipped()
    }

    private func reviewIncomingTagPill(_ tag: HardcoverTagInfo) -> some View {
        let fieldId = tagFieldId(tag.name)
        let isAlreadyCurrent = currentTagKeys.contains(Self.normalizedTagKey(tag.name))
        let isSelected = reviewFields.contains(fieldId)
        let arrowIcon =
            isSelected
            ? (isCompactIOS ? "arrow.up.circle.fill" : "arrow.left.circle.fill")
            : (isCompactIOS ? "arrow.up.circle" : "arrow.left.circle")

        return HStack(spacing: 6) {
            Text(reviewTagShowsCounts ? "\(tag.name) (\(tag.count))" : tag.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: arrowIcon)
                .font(.callout)
                .foregroundStyle(
                    isAlreadyCurrent
                        ? Color.secondary.opacity(0.45)
                        : (isSelected ? Color.white : Color.accentColor)
                )
        }
        .reviewTagPill(isSelected: isSelected)
        .contentShape(Capsule())
        .onTapGesture {
            toggleReviewTag(fieldId: fieldId, isAlreadyCurrent: isAlreadyCurrent)
        }
        .help(isAlreadyCurrent ? "Already in current tags" : "Import this tag")
        .popover(
            isPresented: Binding(
                get: { noChangePopoverRowId == fieldId },
                set: { if !$0 { noChangePopoverRowId = nil } },
            )
        ) {
            Text("Already in current tags")
                .font(.callout)
                .padding()
                .metadataImportCompactPopover()
        }
    }

    private func toggleReviewTag(fieldId: String, isAlreadyCurrent: Bool) {
        guard !isAlreadyCurrent else {
            noChangePopoverRowId = fieldId
            return
        }
        if reviewFields.contains(fieldId) {
            reviewFields.remove(fieldId)
        } else {
            reviewFields.insert(fieldId)
        }
    }

    private func reviewColumn(
        label: String,
        value: String,
        isExpanded: Bool,
        help: String,
        toggleExpansion: @escaping () -> Void,
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            reviewValue(value, isExpanded: isExpanded)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpansion)
                .help(help)
        }
    }

    private func reviewExpansionButton(rowId: String, isExpanded: Bool, label: String) -> some View
    {
        Button {
            expandedReviewRowId = isExpanded ? nil : rowId
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Collapse \(label)" : "Show more \(label)")
    }

    @ViewBuilder
    private func reviewValue(_ value: String, isExpanded: Bool) -> some View {
        if isExpanded {
            Text(value.isEmpty ? "(empty)" : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(value.isEmpty ? "(empty)" : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(6)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 126, alignment: .top)
                .clipped()
        }
    }

    private func reviewRows(for details: HardcoverBookDetails) -> [ReviewRow] {
        reviewSections(for: details).flatMap(\.rows)
    }

    private func reviewSections(for details: HardcoverBookDetails) -> [ReviewRowSection] {
        reviewFieldSections(fallbackDetails: details).compactMap { section in
            let rows = section.fields.compactMap { field in
                makeReviewRow(field: field, details: section.details)
            }
            guard !rows.isEmpty else { return nil }
            return ReviewRowSection(
                id: section.id,
                title: section.title,
                rows: rows.sorted { lhs, rhs in
                    Self.reviewFieldOrder(lhs.id) < Self.reviewFieldOrder(rhs.id)
                },
            )
        }
    }

    private func makeReviewRow(field: String, details: HardcoverBookDetails) -> ReviewRow? {
        guard let label = Self.reviewFieldLabels[field] else { return nil }
        let incoming = incomingValue(field: field, details: details)
        guard !incoming.isEmpty else { return nil }
        return ReviewRow(
            id: field,
            label: label,
            current: currentValue(field: field),
            incoming: incoming,
            currentComparison: comparisonValue(field: field, value: currentValue(field: field)),
            incomingComparison: comparisonValue(field: field, value: incoming),
            details: details,
        )
    }

    private func reviewFieldSections(fallbackDetails: HardcoverBookDetails) -> [(
        id: String, title: String, fields: [String], details: HardcoverBookDetails
    )] {
        var sections:
            [(id: String, title: String, fields: [String], details: HardcoverBookDetails)] = []
        if let audiobookDetails = viewModel.selectedImports[.audiobook] {
            sections.append(("audiobook", "Audiobook Edition", ["narrators"], audiobookDetails))
        }
        let generalDetails =
            generalAssignment?.details ?? ebookAssignment?.details ?? fallbackDetails
        sections.append(("general", "General", Self.generalReviewFields, generalDetails))
        return sections
    }

    private static let generalReviewFields = [
        "title", "subtitle", "description", "language", "publicationDate",
        "rating", "authors", "creators", "series", "tags",
    ]

    private static let reviewFieldLabels: [String: String] = [
        "title": "Title",
        "subtitle": "Subtitle",
        "description": "Description",
        "language": "Language",
        "publicationDate": "Publication Date",
        "rating": "Rating",
        "authors": "Authors",
        "narrators": "Narrators",
        "creators": "Other Creators",
        "series": "Series",
        "tags": "Tags",
    ]

    private static func reviewFieldOrder(_ field: String) -> Int {
        [
            "narrators", "title", "subtitle", "authors", "creators", "publicationDate",
            "language", "series", "rating", "tags", "description",
        ].firstIndex(of: field) ?? Int.max
    }

    private func currentValue(field: String) -> String {
        switch field {
            case "title": return currentBook.title
            case "subtitle": return currentBook.subtitle
            case "description": return currentBook.description
            case "language": return currentBook.language
            case "publicationDate": return currentBook.publicationDate
            case "rating": return currentBook.rating
            case "authors": return currentBook.authors.joined(separator: ", ")
            case "narrators": return currentBook.narrators.joined(separator: ", ")
            case "creators":
                return currentBook.creators.map { "\($0.name) (\($0.role))" }.joined(
                    separator: ", "
                )
            case "series":
                return currentBook.series.map { series in
                    series.position.isEmpty ? series.name : "\(series.name) #\(series.position)"
                }.joined(separator: ", ")
            case "tags": return currentBook.tags.joined(separator: ", ")
            default: return ""
        }
    }

    private func incomingValue(field: String, details: HardcoverBookDetails) -> String {
        switch field {
            case "title": return details.title ?? ""
            case "subtitle": return details.subtitle ?? ""
            case "description": return details.description ?? ""
            case "language": return details.language ?? ""
            case "publicationDate":
                guard let value = details.releaseDate else { return "" }
                return MetadataEditorViewModel.EditableBook.dateOnly(value) ?? value
            case "rating":
                guard let rating = details.rating else { return "" }
                return String(format: "%.2f", rating)
            case "authors": return details.authors.joined(separator: ", ")
            case "narrators": return details.narrators.joined(separator: ", ")
            case "creators":
                return details.creators.map { "\($0.name) (\($0.role))" }.joined(separator: ", ")
            case "series":
                return details.series.map { series in
                    if let position = series.position {
                        return "\(series.name) #\(position.formatted())"
                    }
                    return series.name
                }.joined(separator: ", ")
            case "tags": return details.tags.map(\.name).joined(separator: ", ")
            default: return ""
        }
    }

    private var currentTagKeys: Set<String> {
        Set(currentBook.tags.map(Self.normalizedTagKey))
    }

    private var selectedReviewTagCount: Int {
        reviewFields.filter { $0.hasPrefix("tags:") }.count
    }

    private func reviewImportableTagIds(for details: HardcoverBookDetails) -> Set<String> {
        Set(
            details.tags.compactMap { tag in
                guard
                    HardcoverReviewTagCategory.allCases.contains(where: {
                        $0.contains(tag.category)
                    }),
                    !currentTagKeys.contains(Self.normalizedTagKey(tag.name))
                else { return nil }
                return tagFieldId(tag.name)
            }
        )
    }

    private func sortedReviewTags(_ tags: [HardcoverTagInfo]) -> [HardcoverTagInfo] {
        switch reviewTagSort {
            case .popularity:
                return tags.sorted {
                    if $0.count != $1.count {
                        return $0.count > $1.count
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .alphabetical:
                return tags.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
        }
    }

    private func tagFieldId(_ tag: String) -> String {
        "tags:\(tag)"
    }

    private static func normalizedTagKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func comparisonValue(field: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
            case "publicationDate":
                return MetadataEditorViewModel.EditableBook.dateOnly(trimmed) ?? trimmed
            case "language":
                return Self.normalizedLanguage(trimmed)
            case "tags":
                return Self.normalizedList(trimmed)
            default:
                return trimmed
        }
    }

    private static func normalizedList(_ value: String) -> String {
        var seen = Set<String>()
        var normalized: [String] = []
        for item in value.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            normalized.append(trimmed)
        }
        return normalized.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        .joined(separator: "\n")
    }

    private static func normalizedLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        let english = Locale(identifier: "en")
        for code in Locale.isoLanguageCodes {
            if code.lowercased() == lower {
                return code.lowercased()
            }
            if let localized = english.localizedString(forLanguageCode: code)?.lowercased(),
                localized == lower
            {
                return code.lowercased()
            }
        }
        return lower
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            #if !os(iOS)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            #endif

            if step == .review {
                Button("Back") {
                    step = .search
                    reviewFields.removeAll()
                }
            }

            if let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()

            if step == .search {
                Button("Review Import") {
                    reviewFields.removeAll()
                    step = .review
                }
                .disabled(!hasReviewSelection)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Apply All") {
                    guard let details = selectedTargetDetails else { return }
                    let fields = allReviewFieldIds(for: details)
                    onImport(selectedTargetImports, fields)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedTargetImports.isEmpty
                        || selectedTargetDetails.map { allReviewFieldIds(for: $0).isEmpty }
                            ?? true
                )

                Button("Apply Selected") {
                    onImport(selectedTargetImports, reviewFields)
                    dismiss()
                }
                .disabled(selectedTargetImports.isEmpty || reviewFields.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func allReviewFieldIds(for details: HardcoverBookDetails) -> Set<String> {
        var fields = Set(
            reviewRows(for: details).filter { $0.id != "tags" && $0.differs }.map(\.id)
        )
        fields.formUnion(reviewImportableTagIds(for: details))
        return fields
    }

}
