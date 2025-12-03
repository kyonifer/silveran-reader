import SwiftUI

public struct StorytellerServerSettingsView: View {
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var isLoading = false
    @State private var connectionStatus: ConnectionTestStatus = .notTested
    @State private var hasLoadedCredentials = false
    @State private var isPasswordVisible = false
    @State private var showRemoveDataConfirmation = false
    @State private var isManuallyOffline = false
    @State private var hasSavedCredentials = false

    private enum ConnectionTestStatus: Equatable {
        case notTested
        case testing
        case success
        case failure(String)
    }

    public init() {}

    public var body: some View {
        Form {
            Section("Server Configuration") {
                if isManuallyOffline && hasSavedCredentials {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(
                            "You are currently in offline mode. Press \"Go Online\" to reconnect to the server."
                        )
                        .foregroundColor(.red)
                        .font(.subheadline)
                    }
                    .listRowBackground(Color.red.opacity(0.1))
                }

                TextField("Server URL", text: $serverURL)
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
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPasswordVisible ? "Hide password" : "Show password")
                }
            }

            Section {
                HStack {
                    Button("Save Credentials and Test Connection") {
                        Task {
                            await testConnectionAndSave()
                        }
                    }
                    .disabled(
                        serverURL.isEmpty || username.isEmpty || password.isEmpty || isLoading
                    )

                    Spacer()

                    switch connectionStatus {
                        case .notTested:
                            EmptyView()
                        case .testing:
                            ProgressView()
                                .controlSize(.small)
                        case .success:
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Saved")
                                    .foregroundColor(.secondary)
                            }
                        case .failure(let message):
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                    }
                }

                Button("Clear Saved Credentials", role: .destructive) {
                    Task {
                        await clearCredentials()
                    }
                }
                .disabled(isLoading)

                if hasSavedCredentials {
                    if !isManuallyOffline {
                        Button("Go Offline") {
                            Task {
                                await goOffline()
                            }
                        }
                        .disabled(isLoading)
                    } else {
                        Button("Go Online") {
                            Task {
                                await goOnline()
                            }
                        }
                        .disabled(isLoading)
                    }
                }

                Button("Remove Server Cached Files", role: .destructive) {
                    showRemoveDataConfirmation = true
                }
                .disabled(isLoading)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all downloaded books and metadata from this server?",
            isPresented: $showRemoveDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All Server Data", role: .destructive) {
                Task {
                    await removeServerData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete all downloaded media, covers, and library metadata from the Storyteller server. Your credentials will remain saved. This action cannot be undone."
            )
        }
        .scrollContentBackground(.hidden)
        .modifier(SoftScrollEdgeModifier())
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .center)
        .navigationTitle("Storyteller Server")
        .task {
            await loadExistingCredentials()
        }
    }

    private func loadExistingCredentials() async {
        guard !hasLoadedCredentials else { return }
        hasLoadedCredentials = true

        do {
            if let credentials = try await AuthenticationActor.shared.loadCredentials() {
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
        } catch {
            debugLog(
                "[StorytellerServerSettingsView] Failed to load credentials: \(error.localizedDescription)"
            )
            await MainActor.run {
                hasSavedCredentials = false
            }
        }

        let offlineState = await SettingsActor.shared.config.sync.isManuallyOffline
        await MainActor.run {
            isManuallyOffline = offlineState
        }
    }

    private func testConnectionAndSave() async {
        await MainActor.run {
            isLoading = true
            connectionStatus = .testing
        }

        let success = await StorytellerActor.shared.setLogin(
            baseURL: serverURL,
            username: username,
            password: password
        )

        if success {
            do {
                try await AuthenticationActor.shared.saveCredentials(
                    url: serverURL,
                    username: username,
                    password: password
                )
                try await SettingsActor.shared.updateConfig(isManuallyOffline: false)

                await MainActor.run {
                    isManuallyOffline = false
                    hasSavedCredentials = true
                    isLoading = false
                    connectionStatus = .success
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    connectionStatus = .failure(
                        "Connected but failed to save: \(error.localizedDescription)"
                    )
                }
            }
        } else {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Connection failed")
            }
        }
    }

    private func clearCredentials() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            try await AuthenticationActor.shared.deleteCredentials()
            await StorytellerActor.shared.logout()
            try await SettingsActor.shared.updateConfig(isManuallyOffline: false)

            await MainActor.run {
                serverURL = ""
                username = ""
                password = ""
                connectionStatus = .notTested
                isManuallyOffline = false
                hasSavedCredentials = false
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to clear: \(error.localizedDescription)")
            }
        }
    }

    private func goOffline() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            try await SettingsActor.shared.updateConfig(isManuallyOffline: true)
            await StorytellerActor.shared.logout()

            await MainActor.run {
                isManuallyOffline = true
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to go offline: \(error.localizedDescription)")
            }
        }
    }

    private func goOnline() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            try await SettingsActor.shared.updateConfig(isManuallyOffline: false)

            if let credentials = try await AuthenticationActor.shared.loadCredentials() {
                let success = await StorytellerActor.shared.setLogin(
                    baseURL: credentials.url,
                    username: credentials.username,
                    password: credentials.password
                )

                await MainActor.run {
                    isManuallyOffline = false
                    isLoading = false
                    if success {
                        connectionStatus = .success
                    } else {
                        connectionStatus = .failure("Connection failed")
                    }
                }
            } else {
                await MainActor.run {
                    isManuallyOffline = false
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to go online: \(error.localizedDescription)")
            }
        }
    }

    private func removeServerData() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            try await LocalMediaActor.shared.removeAllStorytellerData()

            await MainActor.run {
                isLoading = false
                connectionStatus = .success
            }
        } catch {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to remove data: \(error.localizedDescription)")
            }
        }
    }
}
