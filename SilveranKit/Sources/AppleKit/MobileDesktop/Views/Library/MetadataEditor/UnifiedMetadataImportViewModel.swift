#if os(iOS) || os(macOS)
import Foundation
import SwiftUI

@MainActor
@Observable
final class UnifiedMetadataImportViewModel {
    enum Column: String, CaseIterable, Identifiable {
        case current
        case audnexus
        case hardcover

        var id: String { rawValue }

        var title: String {
            switch self {
                case .current: return "Current"
                case .audnexus: return "Audnexus"
                case .hardcover: return "Hardcover"
            }
        }
    }

    static let pickerColumns: [Column] = [.audnexus, .hardcover]

    var audnexus = AudnexusImportViewModel()
    var hardcover = HardcoverImportViewModel()

    private var currentBook: MetadataEditorViewModel.EditableBook?

    /// The single chosen Hardcover candidate: work-level, or overlaid with one edition's fields.
    var hardcoverCandidate: BookMetadataCandidate?
    var hardcoverSelectionKey: String?
    var expandedHardcoverResultIds: Set<Int> = []

    /// Which picker the left pane shows. Only `.audnexus`/`.hardcover` are ever set here.
    var pickerSource: Column = .audnexus
    var showCurrentColumn = true

    /// Per scalar field, which column supplies its value. Every field defaults to `.current`
    /// (a no-op import) until the user picks another source.
    var fieldSource: [String: Column] = [:]

    /// Rows expanded to show full (untruncated) values, keyed by field id.
    var expandedFields: Set<String> = []

    /// Final tag set, keyed by lowercased name; mixable across all three columns.
    var selectedTagKeys: Set<String> = []
    private var tagDisplayByKey: [String: String] = [:]

    static let scalarFields = [
        "title", "subtitle", "authors", "narrators", "series",
        "publicationDate", "language", "rating", "creators", "description",
    ]

    static let fieldLabels: [String: String] = [
        "title": "Title",
        "subtitle": "Subtitle",
        "authors": "Authors",
        "narrators": "Narrators",
        "series": "Series",
        "publicationDate": "Release Date",
        "language": "Language",
        "rating": "Rating",
        "creators": "Other Contributors",
        "description": "Description",
    ]

    var audnexusCandidate: BookMetadataCandidate? { audnexus.fetchedDetails?.asMetadataCandidate }

    func candidate(for column: Column) -> BookMetadataCandidate? {
        switch column {
            case .current: return nil
            case .audnexus: return audnexusCandidate
            case .hardcover: return hardcoverCandidate
        }
    }

    var visibleColumns: [Column] {
        showCurrentColumn ? [.current, .audnexus, .hardcover] : [.audnexus, .hardcover]
    }

    /// Whether a source column has a match picked yet. Distinguishes "no match selected" from a
    /// selected match that simply lacks a given field.
    func hasCandidate(_ column: Column) -> Bool {
        switch column {
            case .current: return true
            case .audnexus: return audnexusCandidate != nil
            case .hardcover: return hardcoverCandidate != nil
        }
    }

    func setup(book: MetadataEditorViewModel.EditableBook) async {
        currentBook = book
        for field in Self.scalarFields {
            fieldSource[field] = .current
        }
        for tag in book.tags {
            let key = tag.lowercased()
            selectedTagKeys.insert(key)
            tagDisplayByKey[key] = tag
        }

        audnexus.loadPreferences()
        audnexus.prefill(title: book.title, author: book.authors.first)
        hardcover.prefill(title: book.title, author: book.authors.first)
        await hardcover.loadToken()
        await audnexus.search()
        if hardcover.hasToken {
            await hardcover.search()
        }
    }

    func searchAudnexus() async { await audnexus.search() }
    func selectAudnexus(_ result: AudnexusSearchResult) async {
        await audnexus.selectResult(result)
    }
    func searchHardcover() async { await hardcover.search() }

    func saveHardcoverToken() async {
        await hardcover.saveToken()
        if hardcover.hasToken { await hardcover.search() }
    }

    func expandHardcover(_ result: HardcoverSearchResult) async {
        if expandedHardcoverResultIds.contains(result.id) {
            expandedHardcoverResultIds.remove(result.id)
        } else {
            expandedHardcoverResultIds.insert(result.id)
            if hardcover.infoDetails[result.id] == nil {
                await hardcover.fetchInfo(for: result)
            }
        }
    }

    func selectHardcoverWork(_ result: HardcoverSearchResult) {
        hardcoverCandidate = hardcover.infoDetails[result.id]
        hardcoverSelectionKey = "work-\(result.id)"
    }

    func selectHardcoverEdition(_ edition: BookEditionCandidate, result: HardcoverSearchResult) {
        guard let details = hardcover.detailsForEdition(edition, bookId: result.id) else { return }
        hardcoverCandidate = details
        hardcoverSelectionKey = "edition-\(edition.id)"
    }

    func value(_ field: String, from column: Column) -> String {
        switch column {
            case .current:
                guard let currentBook else { return "" }
                return Self.currentValue(field, from: currentBook)
            default:
                return Self.displayValue(field, candidate(for: column))
        }
    }

    func hasValue(_ field: String, from column: Column) -> Bool {
        !value(field, from: column).isEmpty
    }

    @ObservationIgnored private var descriptionRenderCache: [String: AttributedString] = [:]

    /// Descriptions arrive as HTML, markdown, or a mix depending on the source. Reuse the app-wide
    /// renderer (same one book detail views and widgets use) so the preview matches how the
    /// description will look once imported. Memoized because it parses HTML on each call.
    func renderedDescription(_ raw: String) -> AttributedString {
        if let cached = descriptionRenderCache[raw] { return cached }
        let rendered = BookDescriptionText.attributed(from: raw)
        descriptionRenderCache[raw] = rendered
        return rendered
    }

    func selectField(_ field: String, column: Column) {
        if column != .current, !hasValue(field, from: column) { return }
        fieldSource[field] = column
    }

    func isSelected(_ field: String, column: Column) -> Bool {
        (fieldSource[field] ?? .current) == column
    }

    /// Column header "Select All": takes every value that column offers. Current resets to keep.
    func selectAll(column: Column) {
        for field in Self.scalarFields {
            if column == .current {
                fieldSource[field] = .current
            } else if hasValue(field, from: column) {
                fieldSource[field] = column
            }
        }
        selectAllTags(column: column)
    }

    func tags(for column: Column) -> [String] {
        switch column {
            case .current: return currentBook?.tags ?? []
            case .audnexus: return audnexusCandidate?.tags.map(\.name) ?? []
            case .hardcover: return hardcoverCandidate?.tags.map(\.name) ?? []
        }
    }

    func isTagSelected(_ name: String) -> Bool {
        selectedTagKeys.contains(name.lowercased())
    }

    func toggleTag(_ name: String) {
        let key = name.lowercased()
        if selectedTagKeys.contains(key) {
            selectedTagKeys.remove(key)
        } else {
            selectedTagKeys.insert(key)
            tagDisplayByKey[key] = name
        }
    }

    func allTagsSelected(in column: Column) -> Bool {
        let columnTags = tags(for: column)
        guard !columnTags.isEmpty else { return false }
        return columnTags.allSatisfy { isTagSelected($0) }
    }

    /// Background tap on a tag cell toggles all of that column's tags on or off at once.
    func toggleAllTags(in column: Column) {
        let columnTags = tags(for: column)
        guard !columnTags.isEmpty else { return }
        if allTagsSelected(in: column) {
            for tag in columnTags {
                selectedTagKeys.remove(tag.lowercased())
            }
        } else {
            for tag in columnTags {
                let key = tag.lowercased()
                selectedTagKeys.insert(key)
                tagDisplayByKey[key] = tag
            }
        }
    }

    private func selectAllTags(column: Column) {
        if column == .current {
            selectedTagKeys.removeAll()
            for tag in currentBook?.tags ?? [] {
                let key = tag.lowercased()
                selectedTagKeys.insert(key)
                tagDisplayByKey[key] = tag
            }
        } else {
            for tag in tags(for: column) {
                let key = tag.lowercased()
                selectedTagKeys.insert(key)
                tagDisplayByKey[key] = tag
            }
        }
    }

    private var currentTagKeys: Set<String> {
        Set((currentBook?.tags ?? []).map { $0.lowercased() })
    }

    private var tagsChanged: Bool { selectedTagKeys != currentTagKeys }

    private func selectedTagNames() -> [String] {
        selectedTagKeys.compactMap { tagDisplayByKey[$0] }
    }

    func isExpanded(_ field: String) -> Bool { expandedFields.contains(field) }

    func toggleExpanded(_ field: String) {
        if expandedFields.contains(field) {
            expandedFields.remove(field)
        } else {
            expandedFields.insert(field)
        }
    }

    /// Scalar fields whose source is a real provider (current selections are no-ops), plus the
    /// tags field when the final tag set differs from the book's current tags.
    func selectedFieldIds() -> Set<String> {
        var ids = Set(
            Self.scalarFields.filter { field in
                let column = fieldSource[field] ?? .current
                return column != .current && hasValue(field, from: column)
            }
        )
        if tagsChanged { ids.insert("tags") }
        return ids
    }

    var changedCount: Int { selectedFieldIds().count }

    func buildSyntheticDetails() -> BookMetadataCandidate {
        func pick(_ field: String) -> BookMetadataCandidate? {
            guard let column = fieldSource[field], column != .current else { return nil }
            return candidate(for: column)
        }

        return BookMetadataCandidate(
            title: pick("title")?.title,
            subtitle: pick("subtitle")?.subtitle,
            description: pick("description")?.description,
            releaseDate: pick("publicationDate")?.releaseDate,
            rating: pick("rating")?.rating,
            language: pick("language")?.language,
            authors: pick("authors")?.authors ?? [],
            narrators: pick("narrators")?.narrators ?? [],
            creators: pick("creators")?.creators ?? [],
            series: pick("series")?.series ?? [],
            tags: selectedTagNames().map { BookMetadataTag(name: $0, count: 0, category: nil) },
            editions: [],
        )
    }

    func buildImports() -> [MetadataEditorViewModel.HardcoverImportSource: BookMetadataCandidate] {
        let synthetic = buildSyntheticDetails()
        return [.text: synthetic, .audiobook: synthetic]
    }

    static func displayValue(_ field: String, _ details: BookMetadataCandidate?) -> String {
        guard let details else { return "" }
        switch field {
            case "title": return details.title ?? ""
            case "subtitle": return details.subtitle ?? ""
            case "description": return details.description ?? ""
            case "language": return details.language ?? ""
            case "publicationDate":
                guard let raw = details.releaseDate, !raw.isEmpty else { return "" }
                return raw.contains("T") ? String(raw.prefix(10)) : raw
            case "rating": return details.rating.map { String(format: "%.1f", $0) } ?? ""
            case "authors": return details.authors.joined(separator: ", ")
            case "narrators": return details.narrators.joined(separator: ", ")
            case "creators":
                return details.creators
                    .map { $0.role.isEmpty ? $0.name : "\($0.name) (\($0.role))" }
                    .joined(separator: ", ")
            case "series":
                return details.series
                    .map { s in
                        guard let pos = s.position else { return s.name }
                        let posStr =
                            pos.truncatingRemainder(dividingBy: 1) == 0
                            ? String(Int(pos)) : String(pos)
                        return "\(s.name) #\(posStr)"
                    }
                    .joined(separator: ", ")
            case "tags": return details.tags.map(\.name).joined(separator: ", ")
            default: return ""
        }
    }

    static func currentValue(
        _ field: String,
        from book: MetadataEditorViewModel.EditableBook,
    ) -> String {
        switch field {
            case "title": return book.title
            case "subtitle": return book.subtitle
            case "description": return book.description
            case "language": return book.language
            case "publicationDate": return book.publicationDate
            case "rating": return book.rating
            case "authors": return book.authors.joined(separator: ", ")
            case "narrators": return book.narrators.joined(separator: ", ")
            case "creators":
                return book.creators
                    .map { $0.role.isEmpty ? $0.name : "\($0.name) (\($0.role))" }
                    .joined(separator: ", ")
            case "series":
                return book.series
                    .map { $0.position.isEmpty ? $0.name : "\($0.name) #\($0.position)" }
                    .joined(separator: ", ")
            case "tags": return book.tags.joined(separator: ", ")
            default: return ""
        }
    }
}
#endif
