import AppKit
import SilveranKitAppModel
import StoryAlignCore
import SwiftUI
import UniformTypeIdentifiers

public struct ReadaloudGeneratorView: View {
    @State private var viewModel = ReadaloudGeneratorViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(MediaViewModel.self) private var mediaViewModel
    private let initialData: ReadaloudGeneratorData?

    public init(initialData: ReadaloudGeneratorData? = nil) {
        self.initialData = initialData
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        if isSourceWorkflow {
                            sourceBookSection
                            sourceInputMediaSection
                        } else {
                            inputFilesSection
                        }
                        modelSection
                        outputSection
                    }
                    .frame(width: 360, alignment: .topLeading)

                    Divider()
                        .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 20) {
                        optionsSection
                        if !viewModel.availableChapters.isEmpty {
                            chapterRangeSection
                        }
                    }
                    .frame(width: 360, alignment: .topLeading)
                }
                .padding(20)
            }
            .onChange(of: viewModel.epubURL) { _, _ in
                viewModel.loadChapters()
            }
            if case .processing = viewModel.state {
                Divider()
                progressSection
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            if case .error(let message) = viewModel.state {
                Divider()
                errorSection(message: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            if case .completed(let completion) = viewModel.state {
                Divider()
                completedSection(completion: completion)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            Divider()
            footerView
            Link(
                "Powered by StoryAlign",
                destination: URL(string: "https://codeberg.org/richwaters/StoryAlign")!,
            )
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.bottom, 12)
        }
        .frame(width: 820, height: 760)
        .task {
            await viewModel.loadUploadSources()
            await viewModel.configure(with: initialData)
        }
    }

    private var headerView: some View {
        VStack(spacing: 4) {
            Text("Create Readaloud")
                .font(.headline)
            Text("Align an audiobook with an EPUB to create a synchronized readaloud")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var inputFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input Files")
                .font(.headline)

            filePickerRow(
                label: "EPUB:",
                url: viewModel.epubURL,
                placeholder: "Select EPUB file...",
                allowedTypes: [.epub],
            ) { url in
                viewModel.epubURL = url
            }

            filePickerRow(
                label: "Audiobook:",
                urls: viewModel.audioURLs,
                placeholder: "Select audiobook files...",
                allowedTypes: audioFileTypes,
            ) { urls in
                viewModel.audioURLs = urls
            }
        }
    }

    private var sourceBookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Book")
                .font(.headline)

            lockedSelectionRow(
                iconName: "book.closed",
                title: sourceWorkflowBookTitle,
                detail: "In \(selectedSourceDisplayName)",
            )
        }
    }

    private var sourceInputMediaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input Media")
                .font(.headline)

            VStack(spacing: 8) {
                sourceMediaStatusRow(category: .ebook, title: "EPUB", iconName: "book")
                sourceMediaStatusRow(category: .audio, title: "Audiobook", iconName: "headphones")
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper Model")
                .font(.headline)

            HStack {
                Picker("Model:", selection: $viewModel.selectedModelSize) {
                    ForEach(WhisperModelSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.selectedModelSize == .custom {
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "bin")!]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK {
                            viewModel.customModelPath = panel.url
                        }
                    }
                } else if viewModel.isModelDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Downloaded")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Button("Download") {
                        viewModel.downloadModel()
                    }
                    .disabled(viewModel.state == .processing)
                }
            }

            if viewModel.selectedModelSize == .custom, let customPath = viewModel.customModelPath {
                Text(customPath.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if case .downloading(let progress) = viewModel.state {
                ProgressView(value: progress) {
                    Text("Downloading model...")
                        .font(.caption)
                }
            }
        }
    }

    private var granularityDescription: String {
        switch viewModel.selectedGranularity {
            case .word: return "Highlights one word at a time."
            case .group: return "Highlights small clusters of words based on natural speech timing."
            case .segment: return "Highlights groups based on whisper transcription segments."
            case .phrase: return "Highlights clauses split at punctuation boundaries."
            case .sentence: return "Highlights one full sentence at a time."
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            HStack {
                Text("Granularity:")
                Picker("", selection: $viewModel.selectedGranularity) {
                    Text("Word").tag(Granularity.word)
                    Text("Group (recommended)").tag(Granularity.group)
                    Text("Phrase").tag(Granularity.phrase)
                    Text("Sentence").tag(Granularity.sentence)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Text(granularityDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.selectedGranularity != .sentence {
                Toggle("Expanding highlight", isOn: $viewModel.expandingHighlight)

                Text("Accumulates highlights within a boundary instead of moving one at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.expandingHighlight {
                    HStack {
                        Text("Expansion limit:")
                        Picker("", selection: $viewModel.expansionMode) {
                            Text("Until boundary").tag(ExpansionMode.scope)
                            Text("Fixed count").tag(ExpansionMode.units)
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    if viewModel.expansionMode == .scope {
                        HStack {
                            Text("Expand to:")
                            Picker("", selection: $viewModel.expansionScope) {
                                if viewModel.selectedGranularity == .word
                                    || viewModel.selectedGranularity == .group
                                {
                                    Text("Phrase").tag(Granularity.phrase)
                                }
                                Text("Sentence").tag(Granularity.sentence)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }

                        Text(expansionScopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Max units:")
                            TextField("", value: $viewModel.expansionUnitCount, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text(
                            "Keeps up to \(viewModel.expansionUnitCount) \(viewModel.selectedGranularity.rawValue)s highlighted at once."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var expansionScopeDescription: String {
        let unit = viewModel.selectedGranularity.rawValue
        let boundary = viewModel.expansionScope.rawValue
        return "Highlights accumulate by \(unit) until the end of the \(boundary), then reset."
    }

    private var chapterRangeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapter Range")
                .font(.headline)

            VStack(spacing: 10) {
                HStack {
                    Text("Start:")
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $viewModel.startChapterIndex) {
                        Text("Beginning").tag(nil as Int?)
                        ForEach(viewModel.availableChapters.indices, id: \.self) { i in
                            Text(viewModel.availableChapters[i].name).tag(i as Int?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                HStack {
                    Text("End:")
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $viewModel.endChapterIndex) {
                        Text("End").tag(nil as Int?)
                        ForEach(viewModel.availableChapters.indices, id: \.self) { i in
                            Text(viewModel.availableChapters[i].name).tag(i as Int?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Text("Leave as Beginning/End to include all chapters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        let suggestedName: String? = viewModel.epubURL.map {
            $0.deletingPathExtension().lastPathComponent + "-readaloud.epub"
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text(isSourceWorkflow ? "Destination" : "Output")
                .font(.headline)

            if isSourceWorkflow {
                lockedSelectionRow(
                    iconName: selectedSourceKind == .storyteller ? "server.rack" : "folder",
                    title: "Current book",
                    detail: "Add readaloud to \(selectedSourceDisplayName)",
                )
                .opacity(viewModel.uploadAllToServer ? 1 : 0.45)

                Toggle("Save to folder instead", isOn: customFolderOverrideBinding)
                    .disabled(viewModel.state == .processing)

                if !viewModel.uploadAllToServer {
                    folderPathRow(suggestedFilename: suggestedName)
                }
            } else {
                Toggle(sourceOutputToggleLabel, isOn: $viewModel.uploadAllToServer)
                    .disabled(viewModel.state == .processing)

                if viewModel.uploadAllToServer {
                    Picker("Source:", selection: uploadSourceBinding) {
                        ForEach(viewModel.uploadSources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    .disabled(viewModel.state == .processing || viewModel.uploadSources.isEmpty)
                } else {
                    filePickerRow(
                        label: "Save to:",
                        url: viewModel.outputURL,
                        placeholder: "Select output location...",
                        allowedTypes: [.epub],
                        isSavePanel: true,
                        suggestedFilename: suggestedName,
                    ) { url in
                        viewModel.outputURL = url
                    }
                }
            }
        }
    }

    private var isSourceWorkflow: Bool {
        viewModel.sourceOutputBookID != nil
    }

    private var selectedSourceName: String {
        if let sourceWorkflowName = viewModel.sourceWorkflowName {
            return sourceWorkflowName
        }
        return viewModel.uploadSources.first { $0.id == viewModel.selectedUploadSourceID }?.name
            ?? "source"
    }

    private var sourceWorkflowBookTitle: String {
        viewModel.sourceWorkflowBookTitle ?? "Current book"
    }

    private var selectedSourceDisplayName: String {
        switch selectedSourceKind {
            case .localFolder:
                return "\(selectedSourceName) folder"
            case .storyteller:
                return "\(selectedSourceName) server"
            case nil:
                return selectedSourceName
        }
    }

    private var selectedSourceKind: BookSourceKind? {
        if let sourceWorkflowKind = viewModel.sourceWorkflowKind {
            return sourceWorkflowKind
        }
        return viewModel.uploadSources.first { $0.id == viewModel.selectedUploadSourceID }?.kind
    }

    private var customFolderOverrideBinding: Binding<Bool> {
        Binding(
            get: { !viewModel.uploadAllToServer },
            set: { useCustomFolder in
                viewModel.uploadAllToServer = !useCustomFolder
                if useCustomFolder {
                    viewModel.outputURL = nil
                }
            },
        )
    }

    private var sourceWorkflowBook: BookMetadata? {
        guard let bookID = viewModel.sourceOutputBookID else { return nil }
        return mediaViewModel.library.bookMetaData.first { $0.id == bookID }
    }

    private func lockedSelectionRow(
        iconName: String,
        title: String,
        detail: String,
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Locked from the selected source")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sourceMediaStatusRow(
        category: LocalMediaCategory,
        title: String,
        iconName: String,
    ) -> some View {
        let item = sourceWorkflowBook
        let isDownloaded =
            item.map {
                mediaViewModel.isCategoryDownloaded(category, for: $0)
            } ?? (sourceMediaURL(for: category) != nil)
        let isDownloading =
            item.map {
                mediaViewModel.isCategoryDownloadInProgress(for: $0, category: category)
            } ?? false
        let progress = item.flatMap {
            mediaViewModel.downloadProgressFraction(for: $0, category: category)
        }

        return HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(isDownloaded ? "Downloaded" : "Needed for local alignment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                    .help("\(title) downloaded")
            } else if isDownloading {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress ?? 0))
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round),
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .help("Downloading \(title)")
            } else {
                Button {
                    if let item {
                        mediaViewModel.startDownload(for: item, category: category)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(item == nil)
                .help("Download \(title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sourceMediaURL(for category: LocalMediaCategory) -> URL? {
        switch category {
            case .ebook:
                return viewModel.epubURL
            case .audio:
                return viewModel.audioURLs.first
            case .synced:
                return nil
        }
    }

    private func folderPathRow(suggestedFilename: String?) -> some View {
        HStack {
            Text("Folder:")
            TextField(
                "Folder path",
                text: customOutputFolderBinding(suggestedFilename: suggestedFilename),
            )
            .textFieldStyle(.roundedBorder)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    setOutputFolder(url, suggestedFilename: suggestedFilename)
                }
            }
        }
    }

    private func customOutputFolderBinding(suggestedFilename: String?) -> Binding<String> {
        Binding(
            get: {
                viewModel.outputURL?.deletingLastPathComponent().path ?? ""
            },
            set: { path in
                let expandedPath = NSString(string: path).expandingTildeInPath
                guard !expandedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    viewModel.outputURL = nil
                    return
                }
                setOutputFolder(
                    URL(fileURLWithPath: expandedPath, isDirectory: true),
                    suggestedFilename: suggestedFilename,
                )
            },
        )
    }

    private func setOutputFolder(_ folderURL: URL, suggestedFilename: String?) {
        viewModel.outputURL = folderURL.appendingPathComponent(
            suggestedFilename ?? "readaloud.epub",
            isDirectory: false,
        )
    }

    private var sourceOutputToggleLabel: String {
        let sourceKind = viewModel.uploadSources.first {
            $0.id == viewModel.selectedUploadSourceID
        }?
        .kind
        let sourceName =
            switch sourceKind {
                case .storyteller:
                    "server"
                case .localFolder:
                    "folder source"
                case nil:
                    "source"
            }
        return viewModel.sourceOutputBookID == nil
            ? "Automatically add to \(sourceName) when done"
            : "Automatically update \(sourceName) when done"
    }

    private var uploadSourceBinding: Binding<BookSourceID> {
        Binding(
            get: {
                viewModel.selectedUploadSourceID ?? viewModel.uploadSources.first?.id ?? ""
            },
            set: { viewModel.selectedUploadSourceID = $0 },
        )
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress")
                .font(.headline)

            ProgressView(value: viewModel.overallProgress) {
                HStack {
                    Text(viewModel.currentStage.displayName)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(viewModel.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.currentMessage.isEmpty {
                Text(viewModel.currentMessage)
                    .font(.caption).monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func errorSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Error")
                    .font(.headline)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func completedSection(completion: ReadaloudGeneratorCompletion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Completed")
                    .font(.headline)
            }
            Text(completionMessage(for: completion))
                .font(.caption)

            if case .saved(let url) = completion {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(
                            url.path,
                            inFileViewerRootedAtPath: url.deletingLastPathComponent().path,
                        )
                    }
                    Button("Open") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func completionMessage(for completion: ReadaloudGeneratorCompletion) -> String {
        switch completion {
            case .saved:
                return "Readaloud created successfully!"
            case .uploaded:
                return "Readaloud created and added to the selected source."
            case .replaced:
                return "Readaloud created and replaced in the selected source."
        }
    }

    private var footerView: some View {
        let isDisabled = isCreateReadaloudDisabled

        return VStack(alignment: .trailing, spacing: 8) {
            if case .completed = viewModel.state {
                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                if isDisabled {
                    HStack {
                        Spacer()
                        Text(disabledReason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Cancel") {
                        if case .processing = viewModel.state {
                            viewModel.cancel()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        refreshSourceMediaInputs()
                        if isSourceWorkflowMediaMissing || viewModel.isMissingSourceWorkflowMedia {
                            showDownloadRequiredAlert()
                        } else {
                            viewModel.startAlignment()
                        }
                    } label: {
                        Text("Create Readaloud")
                            .foregroundStyle(
                                isDisabled ? Color(nsColor: .disabledControlTextColor) : .white
                            )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDisabled)
                    .buttonStyle(.borderedProminent)
                    .tint(isDisabled ? Color(nsColor: .disabledControlTextColor) : .accentColor)
                }
            }
        }
        .padding()
    }

    private var isCreateReadaloudDisabled: Bool {
        if case .processing = viewModel.state {
            return true
        }
        if viewModel.isLoadingSourceInputs {
            return true
        }
        if isSourceWorkflowMediaMissing {
            return true
        }
        if !isSourceWorkflow && (viewModel.epubURL == nil || viewModel.audioURLs.isEmpty) {
            return true
        }
        if viewModel.uploadAllToServer {
            return viewModel.selectedUploadSourceID == nil || !viewModel.isModelDownloaded
        }
        return viewModel.outputURL == nil || !viewModel.isModelDownloaded
    }

    private var isSourceWorkflowMediaMissing: Bool {
        guard isSourceWorkflow else { return false }
        guard let item = sourceWorkflowBook else {
            return viewModel.epubURL == nil || viewModel.audioURLs.isEmpty
        }
        return !mediaViewModel.isCategoryDownloaded(.ebook, for: item)
            || !mediaViewModel.isCategoryDownloaded(.audio, for: item)
    }

    private func refreshSourceMediaInputs() {
        guard let bookID = viewModel.sourceOutputBookID else { return }

        let newEpubURL = mediaViewModel.localMediaPath(for: bookID, category: .ebook)
        let newAudioURLs =
            mediaViewModel.localMediaPath(for: bookID, category: .audio)
            .map(resolveSourceAudioURLs) ?? []

        let shouldReloadChapters = viewModel.epubURL == nil && newEpubURL != nil
        viewModel.epubURL = newEpubURL
        viewModel.audioURLs = newAudioURLs
        if shouldReloadChapters {
            viewModel.loadChapters()
        }
    }

    private func resolveSourceAudioURLs(_ url: URL) -> [URL] {
        guard url.lastPathComponent == "manifest.json" else { return [url] }

        struct Manifest: Decodable {
            let readingOrder: [ReadingOrderItem]
        }

        struct ReadingOrderItem: Decodable {
            let href: String
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            return manifest.readingOrder.compactMap { item in
                let audioURL = url.deletingLastPathComponent().appendingPathComponent(item.href)
                return FileManager.default.fileExists(atPath: audioURL.path) ? audioURL : nil
            }
        } catch {
            debugLog("[ReadaloudGenerator] Failed to resolve source audiobook manifest: \(error)")
            return []
        }
    }

    private var disabledReason: String {
        if viewModel.isLoadingSourceInputs {
            return "Loading source media..."
        }
        if isSourceWorkflowMediaMissing {
            return "Download missing media from the Input Media section"
        }
        if viewModel.uploadAllToServer {
            if viewModel.selectedUploadSourceID == nil {
                return "Select an output source"
            }
        } else if viewModel.outputURL == nil {
            return isSourceWorkflow ? "Select output folder" : "Select output location"
        }
        if !isSourceWorkflow {
            if viewModel.epubURL == nil {
                return "Select an EPUB file"
            }
            if viewModel.audioURLs.isEmpty {
                return "Select an audiobook file"
            }
        }
        if !viewModel.isModelDownloaded {
            if viewModel.selectedModelSize == .custom {
                if viewModel.customModelPath == nil {
                    return "Select a custom model file"
                }
                return "Custom model file not found"
            }
            return "Download the Whisper model first"
        }
        return ""
    }

    private func showDownloadRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Download Media First"
        alert.informativeText =
            "Local alignment needs both the ebook and audiobook to be available locally. Use the download buttons in the Input Media section on the left, then try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func filePickerRow(
        label: String,
        url: URL?,
        placeholder: String,
        allowedTypes: [UTType],
        isSavePanel: Bool = false,
        suggestedFilename: String? = nil,
        onSelect: @escaping (URL?) -> Void,
    ) -> some View {
        HStack {
            Text(label)

            Text(url?.lastPathComponent ?? placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Browse...") {
                if isSavePanel {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = allowedTypes
                    panel.nameFieldStringValue =
                        suggestedFilename ?? url?.lastPathComponent ?? "output.epub"
                    if panel.runModal() == .OK {
                        onSelect(panel.url)
                    }
                } else {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = allowedTypes
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK {
                        onSelect(panel.url)
                    }
                }
            }
        }
    }

    private func filePickerRow(
        label: String,
        urls: [URL],
        placeholder: String,
        allowedTypes: [UTType],
        onSelect: @escaping ([URL]) -> Void,
    ) -> some View {
        HStack {
            Text(label)

            Text(audioSelectionLabel(for: urls, placeholder: placeholder))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(urls.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = allowedTypes
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    onSelect(panel.urls)
                }
            }
        }
    }

    private func audioSelectionLabel(for urls: [URL], placeholder: String) -> String {
        switch urls.count {
            case 0:
                return placeholder
            case 1:
                return urls[0].lastPathComponent
            default:
                return "\(urls.count) audiobook files selected"
        }
    }

    private var audioFileTypes: [UTType] {
        [
            UTType(filenameExtension: "m4b"),
            UTType(filenameExtension: "m4a"),
            .mp3,
            UTType(filenameExtension: "flac"),
            UTType(filenameExtension: "aac"),
            UTType(filenameExtension: "ogg"),
            UTType(filenameExtension: "opus"),
            UTType(filenameExtension: "wav"),
            .audio,
        ].compactMap { $0 }
    }
}
