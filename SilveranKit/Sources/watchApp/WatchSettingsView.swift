#if os(watchOS)
import SilveranKitCommon
import SwiftUI

struct WatchSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var sourceName: String = BookSourceKind.storyteller.defaultName
    @State private var storytellerSources: [BookSourceRecord] = []
    @State private var selectedSourceID: BookSourceID?
    @State private var isAddingSource = false
    @State private var isConnecting = false
    @State private var connectionStatus: ConnectionStatus = .disconnected
    @State private var isSyncingFromPhone = false
    @State private var showManualEntry = false
    @State private var hasCredentials = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                .padding(.horizontal)
            }
            .navigationTitle(isEditingSource ? (isAddingSource ? "Add Server" : "Edit Server") : "Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditingSource ? "Back" : "Done") {
                        if isEditingSource {
                            cancelEditingSource()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Remove Server?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible,
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await removeServer()
                    }
                }
            } message: {
                Text("This will remove the server and its cached local data from this watch.")
            }
        }
        .task {
            await loadExistingCredentials()
        }
    }

    private var isEditingSource: Bool {
        isAddingSource || showManualEntry
    }

    @ViewBuilder
    private var content: some View {
        if isEditingSource {
            editorContent
        } else {
            sourceListContent
        }
    }

    private var sourceListContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storyteller Servers")
                .font(.headline)

            if storytellerSources.isEmpty {
                Text("No servers configured.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storytellerSources) { source in
                    Button {
                        Task {
                            await openSource(source)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                            Text(source.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Button {
                startAddingSource()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2)
                    Text("Add Server")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isAddingSource ? "Add Storyteller Server" : sourceName)
                .font(.headline)

            if !isAddingSource {
                statusSection
            }

            syncFromPhoneButton

            manualEntrySection

            if !isAddingSource {
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.caption2)
                        Text("Remove Server")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption2)
            }

            if hasCredentials && !serverURL.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(serverURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch connectionStatus {
            case .connected:
                return "checkmark.circle.fill"
            case .connecting:
                return "arrow.triangle.2.circlepath"
            case .disconnected:
                return "xmark.circle"
            case .error:
                return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch connectionStatus {
            case .connected:
                return .green
            case .connecting:
                return .orange
            case .disconnected:
                return .secondary
            case .error:
                return .red
        }
    }

    private var statusText: String {
        switch connectionStatus {
            case .connected:
                return "Connected"
            case .connecting:
                return "Connecting..."
            case .disconnected:
                return hasCredentials ? "Disconnected" : "Not configured"
            case .error(let message):
                return "Error: \(message)"
        }
    }

    @ViewBuilder
    private var syncFromPhoneButton: some View {
        if WatchSessionManager.shared.isPhoneReachable {
            Button {
                syncFromPhone()
            } label: {
                HStack(spacing: 4) {
                    if isSyncingFromPhone {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "iphone")
                            .font(.caption2)
                    }
                    Text(isSyncingFromPhone ? "Syncing..." : "Sync Login from iPhone")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(isSyncingFromPhone)
        }
    }

    private var manualEntrySection: some View {
        VStack(spacing: 8) {
            Text("Login Credentials")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Server URL", text: $serverURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption2)

            TextField("Name", text: $sourceName)
                .textContentType(.name)
                .font(.caption2)

            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption2)

            SecureField("Password", text: $password)
                .textContentType(.password)
                .font(.caption2)

            Button {
                Task {
                    await connect()
                }
            } label: {
                HStack(spacing: 4) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isConnecting ? "Connecting..." : (isAddingSource ? "Add Server" : "Save and Connect"))
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(isConnecting || serverURL.isEmpty || username.isEmpty || password.isEmpty)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadExistingCredentials() async {
        let previousSelection = selectedSourceID
        storytellerSources = await BookServiceActor.shared.bookSources
            .filter { $0.kind == .storyteller }
        if isEditingSource {
            return
        }
        if let previousSelection,
            storytellerSources.contains(where: { $0.id == previousSelection })
        {
            selectedSourceID = previousSelection
        } else if selectedSourceID == nil || !storytellerSources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = storytellerSources.first?.id
        }
        await loadCredentialsForSelectedSource()
    }

    private func openSource(_ source: BookSourceRecord) async {
        selectedSourceID = source.id
        showManualEntry = true
        await loadCredentialsForSelectedSource()
        showManualEntry = true
    }

    private func loadCredentialsForSelectedSource() async {
        isAddingSource = false
        guard let selectedSourceID else {
            sourceName = BookSourceKind.storyteller.defaultName
            serverURL = ""
            username = ""
            password = ""
            hasCredentials = false
            connectionStatus = .disconnected
            return
        }

        sourceName = storytellerSources.first { $0.id == selectedSourceID }?.name
            ?? BookSourceKind.storyteller.defaultName

        do {
            if let credentials = try await AuthenticationActor.shared.loadCredentials(
                sourceID: selectedSourceID,
            ) {
                serverURL = credentials.url
                username = credentials.username
                password = credentials.password
                hasCredentials = true
            } else {
                serverURL = ""
                username = ""
                password = ""
                hasCredentials = false
                connectionStatus = .disconnected
                return
            }

            connectionStatus = await BookServiceActor.shared.connectionStatus(
                sourceID: selectedSourceID,
            )
        } catch {
            debugLog("[WatchSettingsView] Failed to load credentials: \(error)")
        }
    }

    private func startAddingSource() {
        isAddingSource = true
        selectedSourceID = nil
        sourceName = BookSourceKind.storyteller.defaultName
        serverURL = ""
        username = ""
        password = ""
        hasCredentials = false
        connectionStatus = .disconnected
        errorMessage = nil
        showManualEntry = true
    }

    private func cancelEditingSource() {
        isAddingSource = false
        showManualEntry = false
        errorMessage = nil
        Task {
            await loadExistingCredentials()
        }
    }

    private func syncFromPhone() {
        isSyncingFromPhone = true
        errorMessage = nil

        WatchSessionManager.shared.onCredentialsReceived = { url, user, pass in
            Task { @MainActor in
                serverURL = url
                username = user
                password = pass
                hasCredentials = true
                isSyncingFromPhone = false
                showManualEntry = false

                await connect()
            }
        }

        WatchSessionManager.shared.requestCredentialsFromPhone(sourceID: selectedSourceID)

        Task {
            try? await Task.sleep(for: .seconds(10))
            if isSyncingFromPhone {
                isSyncingFromPhone = false
                errorMessage = "Sync timed out"
            }
        }
    }

    private func connect() async {
        isConnecting = true
        connectionStatus = .connecting
        errorMessage = nil

        do {
            let sourceID = try await saveCurrentSource()
            let success = await BookServiceActor.shared.setLogin(
                sourceID: sourceID,
                baseURL: serverURL,
                username: username,
                password: password,
            )

            if success {
                connectionStatus = .connected
                hasCredentials = true
                showManualEntry = false
            } else {
                connectionStatus = .error("Login failed")
                hasCredentials = true
                errorMessage = "Saved, but could not connect"
            }
        } catch {
            connectionStatus = .error("Save failed")
            errorMessage = error.localizedDescription
        }

        isConnecting = false
    }

    private func removeServer() async {
        guard let selectedSourceID else { return }
        let removed = await BookServiceActor.shared.removeBookSource(id: selectedSourceID)
        if removed {
            self.selectedSourceID = nil
            serverURL = ""
            username = ""
            password = ""
            sourceName = BookSourceKind.storyteller.defaultName
            hasCredentials = false
            connectionStatus = .disconnected
            showManualEntry = false
            errorMessage = nil
            await loadExistingCredentials()
        } else {
            errorMessage = "Failed to remove"
        }
    }

    private func saveCurrentSource() async throws -> BookSourceID {
        if isAddingSource || selectedSourceID == nil {
            guard let record = await BookServiceActor.shared.createBookSource(
                BookSourceConfiguration(
                    kind: .storyteller,
                    name: sourceName,
                    serverURL: serverURL,
                    username: username,
                    password: password,
                ),
            ) else {
                throw WatchSettingsError.saveFailed
            }
            selectedSourceID = record.id
            isAddingSource = false
            await loadExistingCredentials()
            return record.id
        }

        guard let selectedSourceID else {
            throw WatchSettingsError.noSourceSelected
        }

        let saved = await BookServiceActor.shared.updateBookSource(
            id: selectedSourceID,
            configuration: BookSourceConfiguration(
                kind: .storyteller,
                name: sourceName,
                serverURL: serverURL,
                username: username,
                password: password,
            ),
        )
        guard saved else {
            throw WatchSettingsError.saveFailed
        }
        await loadExistingCredentials()
        return selectedSourceID
    }

    private enum WatchSettingsError: LocalizedError {
        case noSourceSelected
        case saveFailed

        var errorDescription: String? {
            switch self {
                case .noSourceSelected:
                    return "No server selected"
                case .saveFailed:
                    return "Failed to save server"
            }
        }
    }
}

#Preview {
    WatchSettingsView()
}
#endif
