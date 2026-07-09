#if os(macOS)
import SwiftUI

/// A single library-table field targeted by a cmd/option-click quick edit. Each case knows the
/// ``MetadataEditorViewModel`` dirty-field key it drives and how it should be rendered, mirroring the
/// full metadata editor's per-field controls.
enum MetadataQuickEditField: Equatable {
    case scalar(key: String, label: String)
    case publicationDate
    case status
    case stringList(key: String, label: String)
    case series
    case collections
    case creators(roleLabel: String)

    var dirtyKey: String {
        switch self {
            case .scalar(let key, _): return key
            case .publicationDate: return "publicationDate"
            case .status: return "status"
            case .stringList(let key, _): return key
            case .series: return "series"
            case .collections: return "collections"
            case .creators: return "creators"
        }
    }

    var label: String {
        switch self {
            case .scalar(_, let label): return label
            case .publicationDate: return "Publication Date"
            case .status: return "Status"
            case .stringList(_, let label): return label
            case .series: return "Series"
            case .collections: return "Collections"
            case .creators(let roleLabel): return roleLabel
        }
    }

    /// Single-line fields commit on plain Return; multi-value editors reserve Return for adding an
    /// item and commit on Cmd+Return instead.
    var isSingleLine: Bool {
        switch self {
            case .scalar, .publicationDate, .status: return true
            default: return false
        }
    }
}

struct MetadataQuickEditTarget: Identifiable {
    let id = UUID()
    let bookId: String
    let field: MetadataQuickEditField
}

/// Lightweight sheet for editing one metadata field of one book, built for rapid-fire edits from the
/// library table. Reuses ``MetadataEditorViewModel`` (dirty tracking, validation, payload build, save)
/// and the same per-field editor controls as the full metadata editor.
struct MetadataQuickEditView: View {
    let bookId: String
    let field: MetadataQuickEditField
    let onClose: () -> Void

    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var viewModel = MetadataEditorViewModel()
    @State private var isReady = false
    @FocusState private var singleLineFocused: Bool

    @State private var hcConfigured = false
    @State private var hcLoading = false
    @State private var hcDetails: HardcoverBookDetails?
    @State private var hcMatchLabel: String?
    @State private var hcError: String?

    private var book: MetadataEditorViewModel.EditableBook? {
        viewModel.books.first { $0.id == bookId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if isReady, book != nil {
                editorArea
                if hcConfigured, fieldSupportsHardcover {
                    if let hcError {
                        Text(hcError)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let hcDetails {
                        hardcoverPeekRow(details: hcDetails)
                    }
                }
                if let message = validationError {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let saveError = viewModel.saveError {
                    Text(saveError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { onClose() }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.headline)
            if let title = book?.displayTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var editorArea: some View {
        if field.isSingleLine {
            editor
        } else {
            ScrollView {
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch field {
            case .scalar(let key, let label):
                TextField(label, text: scalarBinding(key: key))
                    .textFieldStyle(.roundedBorder)
                    .focused($singleLineFocused)
            case .publicationDate:
                publicationDateEditor
            case .status:
                statusEditor
            case .stringList(let key, let label):
                ExpandedStringListEditor(
                    values: stringListBinding(key: key),
                    placeholder: label,
                    suggestions: suggestions(for: key),
                    onChange: { viewModel.markDirty(field: key, for: bookId) },
                )
            case .series:
                SeriesExpandedEditor(
                    series: seriesBinding,
                    suggestions: librarySeriesNames,
                    onChange: { viewModel.markDirty(field: "series", for: bookId) },
                )
            case .collections:
                CollectionsExpandedEditor(
                    collectionUuids: collectionsBinding,
                    choices: viewModel.libraryCollectionChoices,
                    namesByUuid: viewModel.libraryCollectionNamesByUuid,
                    createCollection: { await viewModel.createCollection(named: $0, for: bookId) != nil },
                    deleteCollection: { await viewModel.deleteCollection(uuid: $0, for: bookId) },
                    refreshCollections: {
                        await viewModel.refreshLibraryCollectionsFromServer(for: bookId)
                    },
                    onChange: { viewModel.markDirty(field: "collections", for: bookId) },
                )
            case .creators:
                CreatorsExpandedEditor(
                    creators: creatorsBinding,
                    suggestionsByRole: viewModel.libraryCreatorNamesByRole,
                    onChange: { viewModel.markDirty(field: "creators", for: bookId) },
                )
        }
    }

    private var publicationDateEditor: some View {
        let dateString = book?.publicationDate ?? ""
        let hasDate = !dateString.isEmpty
        return HStack(spacing: 10) {
            MetadataEditorDatePicker(
                selection: Binding(
                    get: { SilveranDate.calendarDay(dateString) ?? Date() },
                    set: { newDate in
                        setPublicationDate(SilveranDate.isoDay(from: newDate))
                    },
                )
            )
            .frame(width: 156)
            .disabled(!hasDate)

            Toggle(
                "No date",
                isOn: Binding(
                    get: { !hasDate },
                    set: { noDate in
                        setPublicationDate(noDate ? "" : SilveranDate.isoDay(from: Date()))
                    },
                )
            )
            .toggleStyle(.checkbox)
        }
    }

    private var statusEditor: some View {
        Picker("", selection: statusBinding) {
            ForEach(statusOptions, id: \.uuid) { status in
                Text(status.name).tag(status.uuid ?? "")
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(statusOptions.isEmpty)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !field.isSingleLine {
                Text("Press \u{2318}\u{21A9} to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hcConfigured, fieldSupportsHardcover {
                if hcLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await lookupHardcover() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Look up this field on Hardcover")
                }
            }
            Button("Cancel", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { Task { await save() } }
                .keyboardShortcut(saveShortcut)
                .disabled(!canSave)
        }
    }

    private var saveShortcut: KeyboardShortcut {
        field.isSingleLine ? .defaultAction : KeyboardShortcut(.return, modifiers: .command)
    }

    private var canSave: Bool {
        guard let book, !viewModel.isSaving else { return false }
        return book.hasDirtyFields && validationError == nil
    }

    private var validationError: String? {
        viewModel.validationErrors(for: bookId).first?.message
    }

    private func load() async {
        viewModel.addBooks(ids: [bookId], from: mediaViewModel.library)
        viewModel.selectedBookId = bookId

        if case .status = field {
            if let sourceID = book?.originalMetadata.sourceID {
                viewModel.availableStatuses = await BookServiceActor.shared.getAvailableStatuses(
                    sourceID: sourceID
                )
            } else if !mediaViewModel.availableStatuses.isEmpty {
                viewModel.availableStatuses = mediaViewModel.availableStatuses
            } else {
                viewModel.availableStatuses = await BookServiceActor.shared.getAvailableStatuses()
            }
        }

        if fieldSupportsHardcover,
            let token = try? await AuthenticationActor.shared.loadHardcoverToken(),
            !token.isEmpty
        {
            await HardcoverActor.shared.setToken(token)
            hcConfigured = true
        }

        isReady = true
        if field.isSingleLine {
            singleLineFocused = true
        }
    }

    private func save() async {
        guard let book else { return }
        guard book.hasDirtyFields else {
            onClose()
            return
        }
        guard validationError == nil else { return }

        await viewModel.saveSingle(bookId, mediaViewModel: mediaViewModel)
        if viewModel.saveError == nil, viewModel.saveResults[bookId] == true {
            onClose()
        }
    }

    private var fieldSupportsHardcover: Bool {
        switch field {
            case .status, .collections: return false
            // Book-level language is not populated by HardcoverActor.fetchBookDetails (it only
            // exists per-edition), and the field stores a language code rather than a display name,
            // so a Hardcover lookup here would show nothing and mis-apply the raw name.
            case .scalar(let key, _): return key != "language"
            default: return true
        }
    }

    @ViewBuilder
    private func hardcoverPeekRow(details: HardcoverBookDetails) -> some View {
        let value = hardcoverValueDisplay(details)
        VStack(alignment: .leading, spacing: 6) {
            if let hcMatchLabel {
                Text("Hardcover match: \(hcMatchLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.isEmpty ? "(no value on Hardcover)" : value)
                    .font(.callout)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button("Use") { applyHardcover(details) }
                    .disabled(value.isEmpty)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func lookupHardcover() async {
        guard let book else { return }
        hcError = nil
        hcLoading = true
        defer { hcLoading = false }

        let author =
            book.authors.first
            ?? book.originalMetadata.authors?.first?.name
            ?? ""
        let query = "\(book.title) \(author)".trimmingCharacters(in: .whitespaces)

        do {
            let results = try await HardcoverActor.shared.searchBooks(query: query)
            guard let first = results.first else {
                hcDetails = nil
                hcMatchLabel = nil
                hcError = "No Hardcover match found"
                return
            }
            hcDetails = try await HardcoverActor.shared.fetchBookDetails(id: first.id)
            hcMatchLabel = first.releaseYear.map { "\(first.title) (\($0))" } ?? first.title
        } catch {
            hcDetails = nil
            hcMatchLabel = nil
            hcError =
                (error as? HardcoverError)?.errorDescription ?? "Hardcover lookup failed"
        }
    }

    private func hardcoverValueDisplay(_ details: HardcoverBookDetails) -> String {
        switch field {
            case .scalar(let key, _):
                switch key {
                    case "title": return details.title ?? ""
                    case "subtitle": return details.subtitle ?? ""
                    default: return ""
                }
            case .stringList(let key, _):
                switch key {
                    case "authors": return details.authors.joined(separator: ", ")
                    case "narrators": return details.narrators.joined(separator: ", ")
                    case "tags": return details.tags.map(\.name).joined(separator: ", ")
                    default: return ""
                }
            case .series:
                return details.series
                    .map { s in
                        let pos = Self.seriesPositionString(s.position)
                        return pos.isEmpty ? s.name : "\(s.name) #\(pos)"
                    }
                    .joined(separator: ", ")
            case .creators:
                return details.creators
                    .map { $0.role.isEmpty ? $0.name : "\($0.name) (\($0.role))" }
                    .joined(separator: ", ")
            case .publicationDate:
                return Self.hardcoverDateOnly(details.releaseDate)
            case .status, .collections:
                return ""
        }
    }

    private func applyHardcover(_ details: HardcoverBookDetails) {
        guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else { return }
        switch field {
            case .scalar(let key, _):
                switch key {
                    case "title": viewModel.books[index].title = details.title ?? ""
                    case "subtitle": viewModel.books[index].subtitle = details.subtitle ?? ""
                    default: break
                }
                viewModel.markDirty(field: key, for: bookId)
            case .stringList(let key, _):
                switch key {
                    case "authors": viewModel.books[index].authors = details.authors
                    case "narrators": viewModel.books[index].narrators = details.narrators
                    case "tags": viewModel.books[index].tags = details.tags.map(\.name)
                    default: break
                }
                viewModel.markDirty(field: key, for: bookId)
            case .series:
                viewModel.books[index].series = details.series.map { s in
                    MetadataEditorViewModel.EditableSeries(
                        name: s.name,
                        position: Self.seriesPositionString(s.position),
                        featured: s.featured,
                        uuid: nil,
                    )
                }
                viewModel.markDirty(field: "series", for: bookId)
            case .creators:
                viewModel.books[index].creators = details.creators.map { creator in
                    MetadataEditorViewModel.EditableCreator(
                        name: creator.name,
                        fileAs: "",
                        role: creator.role,
                        uuid: nil,
                    )
                }
                viewModel.markDirty(field: "creators", for: bookId)
            case .publicationDate:
                viewModel.books[index].publicationDate = Self.hardcoverDateOnly(details.releaseDate)
                viewModel.markDirty(field: "publicationDate", for: bookId)
            case .status, .collections:
                break
        }
    }

    private static func seriesPositionString(_ position: Double?) -> String {
        guard let position else { return "" }
        return position.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(position)) : String(position)
    }

    private static func hardcoverDateOnly(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw.contains("T") ? String(raw.prefix(10)) : raw
    }

    private func setPublicationDate(_ value: String) {
        guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else { return }
        viewModel.books[index].publicationDate = value
        viewModel.markDirty(field: "publicationDate", for: bookId)
    }

    private func scalarBinding(key: String) -> Binding<String> {
        Binding(
            get: { book.map { Self.scalarValue($0, key: key) } ?? "" },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                Self.setScalar(&viewModel.books[index], key: key, value: newValue)
                viewModel.markDirty(field: key, for: bookId)
            },
        )
    }

    private static func scalarValue(
        _ book: MetadataEditorViewModel.EditableBook,
        key: String,
    ) -> String {
        switch key {
            case "title": return book.title
            case "subtitle": return book.subtitle
            case "language": return book.language
            default: return ""
        }
    }

    private static func setScalar(
        _ book: inout MetadataEditorViewModel.EditableBook,
        key: String,
        value: String,
    ) {
        switch key {
            case "title": book.title = value
            case "subtitle": book.subtitle = value
            case "language": book.language = value
            default: break
        }
    }

    private func stringListBinding(key: String) -> Binding<[String]> {
        Binding(
            get: { book?.stringList(for: key) ?? [] },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                switch key {
                    case "authors": viewModel.books[index].authors = newValue
                    case "narrators": viewModel.books[index].narrators = newValue
                    case "tags": viewModel.books[index].tags = newValue
                    default: break
                }
            },
        )
    }

    private var seriesBinding: Binding<[MetadataEditorViewModel.EditableSeries]> {
        Binding(
            get: { book?.series ?? [] },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                viewModel.books[index].series = newValue
            },
        )
    }

    private var collectionsBinding: Binding<[String]> {
        Binding(
            get: { book?.collectionUuids ?? [] },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                viewModel.books[index].collectionUuids = newValue
            },
        )
    }

    private var creatorsBinding: Binding<[MetadataEditorViewModel.EditableCreator]> {
        Binding(
            get: { book?.creators ?? [] },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                viewModel.books[index].creators = newValue
            },
        )
    }

    private var statusBinding: Binding<String> {
        Binding(
            get: { book?.statusUuid ?? "" },
            set: { newValue in
                guard let index = viewModel.books.firstIndex(where: { $0.id == bookId }) else {
                    return
                }
                viewModel.books[index].statusUuid = newValue
                if let status = viewModel.availableStatuses.first(where: { $0.uuid == newValue }) {
                    viewModel.books[index].status = status.name
                }
                viewModel.markDirty(field: "status", for: bookId)
            },
        )
    }

    private var statusOptions: [BookStatus] {
        var statuses = viewModel.availableStatuses
            .filter {
                !($0.uuid ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let current = book,
            !current.statusUuid.isEmpty,
            !statuses.contains(where: { $0.uuid == current.statusUuid })
        else {
            return statuses
        }
        statuses.insert(
            current.originalMetadata.status
                ?? BookStatus(uuid: current.statusUuid, name: current.status),
            at: 0,
        )
        return statuses
    }

    private func suggestions(for key: String) -> [String] {
        switch key {
            case "authors": return viewModel.libraryAuthorNames
            case "narrators": return viewModel.libraryNarratorNames
            case "tags": return viewModel.libraryTagNames
            default: return []
        }
    }

    private var librarySeriesNames: [String] {
        var names = Set<String>()
        for metadata in mediaViewModel.library.bookMetaData {
            for series in metadata.series ?? [] {
                let trimmed = series.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    names.insert(trimmed)
                }
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
#endif
