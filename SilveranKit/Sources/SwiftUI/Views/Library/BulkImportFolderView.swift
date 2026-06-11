import SwiftUI

#if os(macOS)
import AppKit

public struct BulkImportFolderData: Codable, Hashable {
    public var sourceID: BookSourceID?

    public init(sourceID: BookSourceID? = nil) {
        self.sourceID = sourceID
    }
}

public struct BulkImportFolderView: View {
    private let initialSourceID: BookSourceID?
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var bookSources: [BookSourceRecord] = []
    @State private var selectedSourceID: BookSourceID?
    @State private var importFolderURL: URL?
    @State private var groups: [FolderSourceBulkImportGroup] = []
    @State private var skippedFiles: [FolderSourceBulkImportSkippedFile] = []
    @State private var isScanning = false
    @State private var isImporting = false
    @State private var result: ImportResult?

    private enum ImportResult {
        case success(String)
        case failure(String)
    }

    public init(initialSourceID: BookSourceID? = nil) {
        self.initialSourceID = initialSourceID
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                destinationSection
            }
            .formStyle(.grouped)
            .frame(height: 190)

            scanStatusLine

            reviewSection

            Divider()

            HStack {
                Spacer()

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing...")
                        .foregroundStyle(.secondary)
                }

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Import Selected") {
                    Task {
                        await commitImport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport || isScanning || isImporting)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 980, idealWidth: 1080, minHeight: 720, idealHeight: 720)
        .task {
            await loadSources()
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review")
                    .font(.headline)
                BulkImportReviewView(groups: $groups)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        Section("Destination") {
            Picker("Folder Source", selection: selectedSourceBinding) {
                ForEach(folderSources) { source in
                    Label(source.name, systemImage: "folder")
                        .tag(source.id)
                }
            }
            .disabled(isScanning || isImporting || folderSources.isEmpty)
        }

        Section {
            HStack {
                Text("Import Folder")
                    .frame(width: 100, alignment: .leading)
                if let importFolderURL {
                    Text(importFolderURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Choose a folder to scan")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose...") {
                    selectImportFolder()
                }
                .disabled(isScanning || isImporting)
            }
        } footer: {
            Text(
                "Put related ebook, readaloud, and audiobook files in the same folder and use shared names when possible. Silveran detects readaloud EPUBs from media overlays and marks ambiguous matches for review."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var scanStatusLine: some View {
        HStack(spacing: 8) {
            if isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning folder...")
                    .foregroundStyle(.secondary)
            } else if let result {
                switch result {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                }
            } else if !skippedFiles.isEmpty {
                Text("\(skippedFiles.count) skipped while scanning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
    }

    private var folderSources: [BookSourceRecord] {
        bookSources.filter { $0.kind == .localFolder }
    }

    private var selectedSourceBinding: Binding<BookSourceID> {
        Binding(
            get: { selectedSourceID ?? folderSources.first?.id ?? "" },
            set: { selectedSourceID = $0 },
        )
    }

    private var canImport: Bool {
        selectedSourceID != nil
            && importFolderURL != nil
            && groups.contains { $0.isSelected && !$0.importableAssets.isEmpty }
    }

    private func loadSources() async {
        let sources = await BookServiceActor.shared.bookSources
        await MainActor.run {
            bookSources = sources
            let folderSources = sources.filter { $0.kind == .localFolder }
            if let selectedSourceID,
                folderSources.contains(where: { $0.id == selectedSourceID })
            {
                self.selectedSourceID = selectedSourceID
            } else if let initialSourceID,
                folderSources.contains(where: { $0.id == initialSourceID })
            {
                selectedSourceID = initialSourceID
            } else {
                selectedSourceID = folderSources.first?.id
            }
        }
    }

    private func selectImportFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder containing books to bulk import"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await scanImportFolder(url)
            }
        }
    }

    private func scanImportFolder(_ url: URL) async {
        await MainActor.run {
            importFolderURL = url
            groups = []
            skippedFiles = []
            result = nil
            isScanning = true
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let plan = await BookServiceActor.shared.planBulkImportIntoFolderSource(from: url)
        await MainActor.run {
            groups = plan.groups
            skippedFiles = plan.skippedFiles
            isScanning = false
            if plan.groups.isEmpty {
                result = .failure("No supported EPUB or audio files were found.")
            }
        }
    }

    private func commitImport() async {
        guard let sourceID = selectedSourceID, let importFolderURL else { return }

        await MainActor.run {
            isImporting = true
            result = nil
        }

        let accessing = importFolderURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                importFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        let plan = FolderSourceBulkImportPlan(
            rootURL: importFolderURL,
            groups: groups,
            skippedFiles: skippedFiles,
        )
        let commitResult = await BookServiceActor.shared.commitBulkImportIntoFolderSource(
            plan,
            sourceID: sourceID,
        )

        await MainActor.run {
            isImporting = false
            if commitResult.failures.isEmpty {
                result = .success("Imported \(commitResult.importedCount) books")
                groups = []
                skippedFiles = []
                self.importFolderURL = nil
            } else {
                result = .failure(commitResult.failures.prefix(3).joined(separator: "\n"))
            }
        }
        await BookServiceActor.shared.fetchLibraryInformation()
    }
}

private struct BulkImportReviewView: View {
    @Binding var groups: [FolderSourceBulkImportGroup]
    @State private var selectedGroupID: FolderSourceBulkImportGroup.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(selectedCount) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All") {
                    setAllSelected(true)
                }
                .controlSize(.small)
                Button("Select None") {
                    setAllSelected(false)
                }
                .controlSize(.small)
                Button {
                    addBook()
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .controlSize(.small)
            }

            HSplitView {
                BulkImportBookList(
                    groups: $groups,
                    selectedGroupID: selectedGroupBinding,
                    onDeleteEmptyGroup: deleteEmptyGroup,
                )
                .frame(minWidth: 240, idealWidth: 320)

                BulkImportBookDetail(
                    group: selectedGroupBindingValue,
                    allGroups: groups,
                    onMoveAssetToGroup: { assetID, destinationGroupID in
                        guard let selectedGroupID else { return }
                        moveAsset(assetID, from: selectedGroupID, to: destinationGroupID)
                    },
                    onMoveAssetToNewGroup: { assetID in
                        guard let selectedGroupID else { return }
                        moveAssetToNewGroup(assetID, from: selectedGroupID)
                    },
                )
                .frame(minWidth: 360)
            }
            .frame(minHeight: 390)
        }
        .onAppear(perform: repairSelection)
        .onChange(of: groups.map(\.id)) {
            repairSelection()
        }
    }

    private var selectedCount: Int {
        groups.filter(\.isSelected).count
    }

    private var selectedGroupBinding: Binding<FolderSourceBulkImportGroup.ID?> {
        Binding(
            get: {
                selectedGroupID
            },
            set: { newValue in
                selectedGroupID = newValue
            },
        )
    }

    private var selectedGroupBindingValue: Binding<FolderSourceBulkImportGroup>? {
        guard let selectedGroupID,
            let index = groups.firstIndex(where: { $0.id == selectedGroupID })
        else {
            return nil
        }

        return $groups[index]
    }

    private func setAllSelected(_ selected: Bool) {
        for index in groups.indices {
            groups[index].isSelected = selected
        }
    }

    private func addBook() {
        let group = FolderSourceBulkImportGroup(title: "Untitled Book", assets: [])
        groups.append(group)
        selectedGroupID = group.id
    }

    private func deleteEmptyGroup(_ groupID: FolderSourceBulkImportGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].assets.isEmpty
        else {
            return
        }

        groups.remove(at: index)
        repairSelection()
    }

    private func moveAsset(
        _ assetID: FolderSourceBulkImportAsset.ID,
        from sourceGroupID: FolderSourceBulkImportGroup.ID,
        to destinationGroupID: FolderSourceBulkImportGroup.ID,
    ) {
        guard sourceGroupID != destinationGroupID,
            let sourceIndex = groups.firstIndex(where: { $0.id == sourceGroupID }),
            let assetIndex = groups[sourceIndex].assets.firstIndex(where: { $0.id == assetID }),
            let destinationIndex = groups.firstIndex(where: { $0.id == destinationGroupID })
        else {
            return
        }

        let asset = groups[sourceIndex].assets.remove(at: assetIndex)
        groups[destinationIndex].assets.append(asset)
    }

    private func moveAssetToNewGroup(
        _ assetID: FolderSourceBulkImportAsset.ID,
        from groupID: FolderSourceBulkImportGroup.ID,
    ) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
            let assetIndex = groups[groupIndex].assets.firstIndex(where: { $0.id == assetID })
        else {
            return
        }

        let asset = groups[groupIndex].assets.remove(at: assetIndex)
        let title = asset.detectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = URL(fileURLWithPath: asset.filename).deletingPathExtension()
            .lastPathComponent
        let newGroup = FolderSourceBulkImportGroup(
            title: title?.isEmpty == false ? title! : fallbackTitle,
            isSelected: groups[groupIndex].isSelected,
            assets: [asset],
        )
        groups.insert(newGroup, at: groupIndex + 1)
        selectedGroupID = newGroup.id
    }

    private func repairSelection() {
        if let selectedGroupID, groups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        selectedGroupID = groups.first?.id
    }
}

private struct BulkImportBookList: View {
    @Binding var groups: [FolderSourceBulkImportGroup]
    @Binding var selectedGroupID: FolderSourceBulkImportGroup.ID?
    let onDeleteEmptyGroup: (FolderSourceBulkImportGroup.ID) -> Void

    var body: some View {
        List(selection: $selectedGroupID) {
            ForEach($groups) { $group in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("Import", isOn: $group.isSelected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookTitle(group))
                            .font(.body)
                            .lineLimit(2)
                            .help(bookTitle(group))
                        Text(assetSummary(group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if group.assets.isEmpty {
                        Button {
                            onDeleteEmptyGroup(group.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove empty book")
                    }
                }
                .padding(.vertical, 4)
                .tag(group.id as FolderSourceBulkImportGroup.ID?)
            }
        }
        .listStyle(.sidebar)
    }

    private func bookTitle(_ group: FolderSourceBulkImportGroup) -> String {
        let title = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Book" : title
    }

    private func assetSummary(_ group: FolderSourceBulkImportGroup) -> String {
        if group.assets.isEmpty {
            return "No files"
        }

        let roles = FolderSourceBulkImportRole.allCases
            .filter { role in
                role != .skip && group.assets.contains { $0.selectedRole == role }
            }
            .map(\.displayName)

        if roles.isEmpty {
            return "\(group.assets.count) skipped"
        }

        return roles.joined(separator: ", ")
    }
}

private struct BulkImportBookDetail: View {
    var group: Binding<FolderSourceBulkImportGroup>?
    let allGroups: [FolderSourceBulkImportGroup]
    let onMoveAssetToGroup: (FolderSourceBulkImportAsset.ID, FolderSourceBulkImportGroup.ID) -> Void
    let onMoveAssetToNewGroup: (FolderSourceBulkImportAsset.ID) -> Void

    var body: some View {
        Group {
            if let group {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Book title", text: group.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)

                    HStack(spacing: 12) {
                        Text("\(group.wrappedValue.assets.count) files")
                            .foregroundStyle(.secondary)
                        if !group.wrappedValue.isSelected {
                            Label("Not selected for import", systemImage: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)

                    ForEach(group.warnings.wrappedValue, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if group.wrappedValue.assets.isEmpty {
                        BulkImportEmptyFileList()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(group.assets) { $asset in
                                    BulkImportAssetAssignmentRow(
                                        asset: $asset,
                                        currentGroupID: group.wrappedValue.id,
                                        allGroups: allGroups,
                                        onMoveToGroup: { destinationGroupID in
                                            onMoveAssetToGroup(asset.id, destinationGroupID)
                                        },
                                        onMoveToNewGroup: {
                                            onMoveAssetToNewGroup(asset.id)
                                        },
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                BulkImportEmptyFileList(message: "Select a book to review its files.")
            }
        }
    }
}

private struct BulkImportEmptyFileList: View {
    var message = "No files in this book."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BulkImportAssetAssignmentRow: View {
    @Binding var asset: FolderSourceBulkImportAsset
    let currentGroupID: FolderSourceBulkImportGroup.ID
    let allGroups: [FolderSourceBulkImportGroup]
    let onMoveToGroup: (FolderSourceBulkImportGroup.ID) -> Void
    let onMoveToNewGroup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Picker("", selection: $asset.selectedRole) {
                    ForEach(FolderSourceBulkImportRole.allCases, id: \.self) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 118, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.relativePath)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(asset.relativePath)
                    HStack(spacing: 8) {
                        Text("Detected: \(asset.detectedRole.displayName)")
                        if let fileSize = asset.fileSize {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: fileSize,
                                    countStyle: .file,
                                )
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button {
                        onMoveToNewGroup()
                    } label: {
                        Label("New Book", systemImage: "plus.rectangle.on.rectangle")
                    }

                    if !allGroups.isEmpty {
                        Divider()
                        ForEach(allGroups) { destination in
                            if destination.id == currentGroupID {
                                Label(bookTitle(destination), systemImage: "checkmark")
                                    .foregroundStyle(.secondary)
                                    .disabled(true)
                            } else {
                                Button {
                                    onMoveToGroup(destination.id)
                                } label: {
                                    Label(bookTitle(destination), systemImage: "arrow.right")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Move", systemImage: "arrow.right.circle")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Move this file into another proposed book")
            }

            ForEach(asset.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 128)
            }
        }
        .padding(.vertical, 2)
    }

    private func bookTitle(_ destination: FolderSourceBulkImportGroup) -> String {
        let title = destination.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Book" : title
    }
}
#endif
