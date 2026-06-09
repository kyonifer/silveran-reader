import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

public struct StorytellerServerSettingsView: View {
    @State private var sources: [BookSourceRecord] = []
    @State private var sourceURLs: [BookSourceID: String] = [:]
    @State private var isLoading = false
    @State private var showingAddServer = false
    #if os(macOS)
    @State private var editingSource: BookSourceRecord?
    #endif

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text(
                    "Book sources are where Silveran Reader acquires books, such as a local folder or a remote Storyteller server."
                )
                .foregroundStyle(.secondary)
            }

            Section("Book Sources") {
                if isLoading && sources.isEmpty {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading Sources")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sources) { source in
                        #if os(macOS)
                        Button {
                            editingSource = source
                        } label: {
                            sourceRow(for: source)
                        }
                        .buttonStyle(.plain)
                        #else
                        NavigationLink {
                            BookSourceEditorView(source: source) {
                                await loadSources()
                            }
                        } label: {
                            sourceRow(for: source)
                        }
                        #endif
                    }
                }

                Button {
                    showingAddServer = true
                } label: {
                    Label("Add Book Source", systemImage: "plus")
                }
            }

            Section {
                addFilesHelpButton
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(SoftScrollEdgeModifier())
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, alignment: .center)
        .navigationTitle("Book Sources")
        .task {
            await loadSources()
        }
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                BookSourceEditorView(source: nil) {
                    await loadSources()
                    await MainActor.run {
                        showingAddServer = false
                    }
                }
            }
        }
        #if os(macOS)
        .sheet(item: $editingSource) { source in
            NavigationStack {
                BookSourceEditorView(source: source) {
                    await loadSources()
                    await MainActor.run {
                        editingSource = nil
                    }
                }
            }
        }
        #endif
    }

    private func loadSources() async {
        await MainActor.run {
            isLoading = true
        }
        let loadedSources = await BookServiceActor.shared.bookSources
        var urls: [BookSourceID: String] = [:]
        for source in loadedSources where source.kind == .storyteller {
            if let credentials = await BookServiceActor.shared.credentials(for: source.id) {
                urls[source.id] = credentials.url
            }
        }
        await MainActor.run {
            sources = loadedSources
            sourceURLs = urls
            isLoading = false
        }
    }

    private var addFilesHelpButton: some View {
        AddFilesHelpButton(title: "How do I add files to these sources?")
    }

    private func sourceRow(for source: BookSourceRecord) -> some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text(sourceDetail(for: source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                #if os(macOS)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                #endif
            }
        } icon: {
            Image(systemName: iconName(for: source.kind))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sourceDetail(for source: BookSourceRecord) -> String {
        switch source.kind {
            case .storyteller:
                return sourceURLs[source.id] ?? "No URL saved"
            case .localFolder:
                return source.storagePath ?? "No folder selected"
        }
    }

    private func iconName(for kind: BookSourceKind) -> String {
        switch kind {
            case .storyteller:
                return "server.rack"
            case .localFolder:
                return "folder"
        }
    }
}

struct BookSourceEditorView: View {
    let source: BookSourceRecord?
    let onSaved: () async -> Void

    @State private var kind: BookSourceKind = .storyteller
    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var folderPath = ""
    @State private var folderBookmarkData: Data?
    @State private var originalFolderPath = ""
    @State private var originalFolderBookmarkData: Data?
    @State private var hasLoadedCredentials = false
    @State private var hasSavedCredentials = false
    @State private var isLoading = false
    @State private var isPasswordVisible = false
    @State private var showingFolderImporter = false
    @State private var connectionStatus: ConnectionTestStatus = .notTested
    @State private var showRemoveDataConfirmation = false

    @Environment(\.dismiss) private var dismiss

    init(source: BookSourceRecord?, onSaved: @escaping () async -> Void) {
        self.source = source
        self.onSaved = onSaved

        let initialKind = source?.kind ?? .storyteller
        _kind = State(initialValue: initialKind)
        _name = State(initialValue: source?.name ?? Self.defaultName(for: initialKind))
        _folderPath = State(initialValue: source?.storagePath ?? "")
        _folderBookmarkData = State(initialValue: source?.storageBookmarkData)
        _originalFolderPath = State(initialValue: source?.storagePath ?? "")
        _originalFolderBookmarkData = State(initialValue: source?.storageBookmarkData)
    }

    private enum ConnectionTestStatus: Equatable {
        case notTested
        case testing
        case success
        case failure(String)
    }

    private var sourceID: BookSourceID? {
        source?.id
    }

    private var isExistingSource: Bool {
        source != nil
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isLoading else {
            return false
        }
        switch kind {
            case .storyteller:
                return !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !password.isEmpty
            case .localFolder:
                return !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasFolderChanges: Bool {
        folderPath != originalFolderPath || folderBookmarkData != originalFolderBookmarkData
    }

    var body: some View {
        Form {
            Section("Source Configuration") {
                Picker("Type", selection: $kind) {
                    Text(BookSourceKind.storyteller.displayName).tag(BookSourceKind.storyteller)
                    Text(BookSourceKind.localFolder.displayName).tag(BookSourceKind.localFolder)
                }
                .disabled(isExistingSource)
                .onChange(of: kind) { _, newKind in
                    guard !isExistingSource else { return }
                    name = defaultName(for: newKind)
                }

                TextField("Name", text: $name)
                    .textContentType(.name)

                switch kind {
                    case .storyteller:
                        TextField(
                            "Server URL",
                            text: $serverURL,
                            prompt: Text(verbatim: "https://my.example.com")
                                .foregroundStyle(.secondary),
                        )
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .help("e.g., https://storyteller.example.com")

                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        HStack {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                                    .textContentType(.password)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                            }

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isPasswordVisible ? "Hide password" : "Show password")
                        }
                    case .localFolder:
                        HStack {
                            TextField("Folder", text: $folderPath)
                                .textContentType(.URL)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if hasFolderChanges {
                                Button {
                                    folderPath = originalFolderPath
                                    folderBookmarkData = originalFolderBookmarkData
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .help("Revert folder")
                            }

                            #if os(macOS)
                            if isExistingSource {
                                Button {
                                    revealFolderInFinder()
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                                .disabled(folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            #endif

                            Button {
                                showingFolderImporter = true
                            } label: {
                                Image(systemName: isExistingSource ? "pencil" : "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Choose folder")
                        }
                        .fileImporter(
                            isPresented: $showingFolderImporter,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false,
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                setFolderURL(url)
                            }
                        }
                }
            }

            #if os(iOS)
            Section {
                actionRowButton(
                    title: primaryActionTitle,
                    isDisabled: !canSave,
                    status: saveStatusIcon,
                ) {
                    await saveSource()
                }

                if isExistingSource && kind == .storyteller {
                    actionRowButton(
                        title: "Test Connection",
                        isDisabled: isLoading || !canSave,
                        status: connectionStatusIcon,
                    ) {
                        await testConnection()
                    }
                }

                if isExistingSource {
                    Button(role: .destructive) {
                        showRemoveDataConfirmation = true
                    } label: {
                        Label(removeActionTitle, systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(isLoading)
                }
            }
            #endif

            if case .failure(let message) = connectionStatus {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title2)
                        failureMessage(message)
                    }
                }
            }

            if let sourceID {
                Section("Details") {
                    LabeledContent("Source ID", value: sourceID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                addFilesHelpButton
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(SoftScrollEdgeModifier())
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .center)
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            macActionBar
        }
        #endif
        .navigationTitle(isExistingSource ? name : "Add Book Source")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            if !isExistingSource {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            #endif
        }
        .alert(removeConfirmationTitle, isPresented: $showRemoveDataConfirmation) {
            Button(removeActionTitle, role: .destructive) {
                Task {
                    await removeSource()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmationMessage)
        }
        .task {
            await loadExistingSource()
        }
    }

    #if os(macOS)
    private var macActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if isExistingSource {
                    Button(role: .destructive) {
                        showRemoveDataConfirmation = true
                    } label: {
                        Label(removeActionTitle, systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(isLoading)
                }

                if shouldShowConnectionStatus {
                    connectionStatusView
                }

                Spacer()

                Button(isExistingSource ? "Close" : "Cancel") {
                    dismiss()
                }

                if isExistingSource && kind == .storyteller {
                    Button("Test Connection") {
                        Task {
                            await testConnection()
                        }
                    }
                    .disabled(isLoading || !canSave)
                }

                Button(primaryActionTitle) {
                    Task {
                        await saveSource()
                    }
                }
                .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
    #endif

    private var addFilesHelpButton: some View {
        AddFilesHelpButton(title: "How do I add files to this source?")
    }

    private var primaryActionTitle: String {
        switch kind {
            case .storyteller:
                return isExistingSource ? "Save Credentials" : "Add Server"
            case .localFolder:
                return isExistingSource ? "Save Folder Source" : "Add Folder Source"
        }
    }

    private var removeActionTitle: String {
        switch kind {
            case .storyteller:
                return "Remove Server"
            case .localFolder:
                return "Remove Folder Source"
        }
    }

    private var removeConfirmationTitle: String {
        switch kind {
            case .storyteller:
                return "Remove this server?"
            case .localFolder:
                return "Remove this folder source?"
        }
    }

    private var removeConfirmationMessage: String {
        switch kind {
            case .storyteller:
                return
                    "This will delete saved credentials, cached metadata, downloaded media, and covers for books from this server."
            case .localFolder:
                return
                    "This removes the source from Silveran Reader. Files in the selected folder are not deleted."
        }
    }

    private var shouldShowConnectionStatus: Bool {
        connectionStatus != .notTested
    }

    @ViewBuilder
    private func actionRowButton(
        title: String,
        isDisabled: Bool,
        status: some View,
        action: @escaping () async -> Void,
    ) -> some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                status
            }
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var saveStatusIcon: some View {
        if isLoading {
            EmptyView()
        } else if hasSavedCredentials {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        switch connectionStatus {
            case .notTested:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
            case .notTested:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
            case .success:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .foregroundStyle(.secondary)
                }
            case .failure:
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Failed")
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func failureMessage(_ message: String) -> some View {
        if message.lowercased().contains("credentials") {
            Text("Invalid username or password. Please check your credentials and try again.")
                .font(.body)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.body)
                Text("If you just allowed local network access, try connecting again.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadExistingCredentials() async {
        await loadExistingSource()
    }

    private func loadExistingSource() async {
        guard !hasLoadedCredentials else { return }
        hasLoadedCredentials = true

        await MainActor.run {
            let sourceKind = source?.kind ?? .storyteller
            kind = sourceKind
            name = source?.name ?? defaultName(for: sourceKind)
            folderPath = source?.storagePath ?? ""
            folderBookmarkData = source?.storageBookmarkData
            originalFolderPath = source?.storagePath ?? ""
            originalFolderBookmarkData = source?.storageBookmarkData
        }

        guard let sourceID, source?.kind == .storyteller else { return }

        if let credentials = await BookServiceActor.shared.credentials(for: sourceID) {
            await MainActor.run {
                serverURL = credentials.url
                username = credentials.username
                password = credentials.password
                hasSavedCredentials = true
            }
        } else {
            await MainActor.run {
                hasSavedCredentials = false
            }
        }
    }

    private func saveSource() async {
        await MainActor.run {
            isLoading = true
            connectionStatus = .notTested
        }

        let configuration = BookSourceConfiguration(
            kind: kind,
            name: name,
            serverURL: serverURL,
            username: username,
            password: password,
            storagePath: folderPath,
            storageBookmarkData: folderBookmarkData,
        )
        let success: Bool
        if let sourceID {
            success = await BookServiceActor.shared.updateBookSource(
                id: sourceID,
                configuration: configuration,
            )
        } else {
            let record = await BookServiceActor.shared.createBookSource(configuration)
            success = record != nil
        }

        if success {
            await onSaved()
            await MainActor.run {
                hasSavedCredentials = true
                isLoading = false
                connectionStatus = .notTested
                originalFolderPath = folderPath
                originalFolderBookmarkData = folderBookmarkData
            }
        } else {
            let message = await failureMessageForCurrentSource()
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure(message)
            }
        }
    }

    private func testConnection() async {
        guard let sourceID else { return }

        await MainActor.run {
            isLoading = true
            connectionStatus = .testing
        }

        let success = await BookServiceActor.shared.testBookSourceConnection(sourceID: sourceID)

        await MainActor.run {
            isLoading = false
            if success {
                hasSavedCredentials = true
                connectionStatus = .success
            } else {
                connectionStatus = .failure("Could not connect to this server.")
            }
        }
    }

    private func removeSource() async {
        guard let sourceID else { return }

        await MainActor.run {
            isLoading = true
        }

        let success = await BookServiceActor.shared.removeBookSource(id: sourceID)
        if success {
            await onSaved()
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        } else {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to remove source.")
            }
        }
    }

    private func failureMessageForCurrentSource() async -> String {
        if kind == .localFolder {
            return
                "Could not save folder source. The selected folder may already belong to another source."
        }
        guard let sourceID else { return "Connection failed." }
        let storytellerStatus = await BookServiceActor.shared.connectionStatus(sourceID: sourceID)
        if case .error(let message) = storytellerStatus {
            return message
        }
        return "Connection failed."
    }

    private func setFolderURL(_ url: URL) {
        folderPath = url.path
        #if os(macOS)
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        folderBookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
        #elseif os(iOS)
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        folderBookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
        #else
        folderBookmarkData = nil
        #endif
    }

    #if os(macOS)
    private func revealFolderInFinder() {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private static func defaultName(for kind: BookSourceKind) -> String {
        switch kind {
            case .storyteller:
                return BookSourceKind.storyteller.defaultName
            case .localFolder:
                return BookSourceKind.localFolder.defaultName
        }
    }

    private func defaultName(for kind: BookSourceKind) -> String {
        Self.defaultName(for: kind)
    }
}

private struct AddFilesHelpButton: View {
    let title: String
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Text(title)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingHelp, attachmentAnchor: .point(.center), arrowEdge: .top) {
            AddFilesHelpPopover()
        }
    }
}

private struct AddFilesHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adding Books")
                .font(.headline)
            Text("Go to All Books, click Add Book, then choose the destination source.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}
