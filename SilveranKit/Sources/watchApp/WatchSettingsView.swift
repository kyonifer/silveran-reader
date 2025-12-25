#if os(watchOS)
import SilveranKitCommon
import SwiftUI

struct WatchSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Storyteller Server")
                        .font(.headline)

                    statusSection

                    if hasCredentials {
                        credentialActions
                    } else {
                        setupActions
                    }

                    if showManualEntry {
                        manualEntrySection
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Remove Server?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await removeServer()
                    }
                }
            } message: {
                Text("This will clear your login credentials.")
            }
        }
        .task {
            await loadExistingCredentials()
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

    private var setupActions: some View {
        VStack(spacing: 8) {
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

            Button {
                withAnimation {
                    showManualEntry = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.caption2)
                    Text("Enter Login Manually")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .tint(.secondary)
        }
    }

    private var credentialActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credentials")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if WatchSessionManager.shared.isPhoneReachable {
                Button {
                    syncFromPhone()
                } label: {
                    HStack(spacing: 4) {
                        if isSyncingFromPhone {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                        }
                        Text(isSyncingFromPhone ? "Syncing..." : "Re-sync from iPhone")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(isSyncingFromPhone)
            }

            Button {
                withAnimation {
                    showManualEntry = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                    Text("Edit Manually")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .tint(.secondary)

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
                    Text(isConnecting ? "Connecting..." : "Connect")
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
        do {
            if let credentials = try await AuthenticationActor.shared.loadCredentials() {
                serverURL = credentials.url
                username = credentials.username
                password = credentials.password
                hasCredentials = true

                connectionStatus = await StorytellerActor.shared.connectionStatus
            }
        } catch {
            debugLog("[WatchSettingsView] Failed to load credentials: \(error)")
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

        WatchSessionManager.shared.requestCredentialsFromPhone()

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
            try await AuthenticationActor.shared.saveCredentials(
                url: serverURL,
                username: username,
                password: password
            )

            let success = await StorytellerActor.shared.setLogin(
                baseURL: serverURL,
                username: username,
                password: password
            )

            if success {
                connectionStatus = .connected
                hasCredentials = true
                showManualEntry = false
            } else {
                connectionStatus = .error("Login failed")
                errorMessage = "Check credentials"
            }
        } catch {
            connectionStatus = .error("Save failed")
            errorMessage = error.localizedDescription
        }

        isConnecting = false
    }

    private func removeServer() async {
        do {
            try await AuthenticationActor.shared.deleteCredentials()
            _ = await StorytellerActor.shared.logout()

            serverURL = ""
            username = ""
            password = ""
            hasCredentials = false
            connectionStatus = .disconnected
            showManualEntry = false
            errorMessage = nil
        } catch {
            errorMessage = "Failed to remove"
        }
    }
}

#Preview {
    WatchSettingsView()
}
#endif
