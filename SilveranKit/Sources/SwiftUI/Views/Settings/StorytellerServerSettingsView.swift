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
    @State private var hasSavedCredentials = false
    @State private var hasTriggeredNetworkPrompt = false

    @Environment(MediaViewModel.self) private var mediaViewModel

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
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                    #endif
                    .help("e.g., https://storyteller.example.com")
                    .onChange(of: serverURL) { _, newValue in
                        if !hasTriggeredNetworkPrompt && !newValue.isEmpty {
                            hasTriggeredNetworkPrompt = true
                            triggerNetworkPermissionPrompt()
                        }
                    }

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
            }

            Section {
                HStack {
                    Button("Save Credentials and Connect") {
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
                            if hasSavedCredentials && mediaViewModel.lastNetworkOpSucceeded == true {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Connected")
                                        .foregroundStyle(.secondary)
                                }
                            }
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

                if hasSavedCredentials {
                    Button("Remove Server", role: .destructive) {
                        showRemoveDataConfirmation = true
                    }
                    .disabled(isLoading)
                }
            }

            if case .failure(let message) = connectionStatus {
                if message.lowercased().contains("credentials") {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title2)
                            Text("Invalid username or password. Please check your credentials and try again.")
                                .font(.body)
                        }
                    }
                } else {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Connection failed. This could be because:")
                                    .font(.body)
                                Text("- The server is down or unreachable")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Text("- Local network access permission was denied")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("If you just allowed local network access, try connecting again.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            #if os(iOS)
                            Text("If you previously denied local network access, you may need to enable it in Settings > Privacy & Security > Local Network.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            #else
                            Text("If you previously denied local network access, you may need to enable it in System Settings > Privacy & Security > Local Network.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            #endif
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove this server?",
            isPresented: $showRemoveDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) {
                Task {
                    await removeServer()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete your saved credentials and all downloaded media, covers, and library metadata from this server. This action cannot be undone."
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
                await MainActor.run {
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
            let storytellerStatus = await StorytellerActor.shared.connectionStatus
            await MainActor.run {
                isLoading = false
                if case .error(let message) = storytellerStatus {
                    connectionStatus = .failure(message)
                } else {
                    connectionStatus = .failure("Connection failed")
                }
            }
        }
    }

    private func removeServer() async {
        await MainActor.run {
            isLoading = true
        }

        do {
            try await LocalMediaActor.shared.removeAllStorytellerData()
            try await AuthenticationActor.shared.deleteCredentials()
            _ = await StorytellerActor.shared.logout()

            await MainActor.run {
                serverURL = ""
                username = ""
                password = ""
                connectionStatus = .notTested
                hasSavedCredentials = false
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                connectionStatus = .failure("Failed to remove: \(error.localizedDescription)")
            }
        }
    }

    private func triggerNetworkPermissionPrompt() {
        Task.detached(priority: .background) {
            let url = URL(string: "http://192.168.0.1/")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 0.5
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
