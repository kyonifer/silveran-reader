import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct TVSettingsView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = TVSettingsViewModel()

    private var isConnected: Bool {
        mediaViewModel.connectionStatus == .connected
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Connection") {
                    TextField("Server URL", text: $settingsViewModel.serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()

                    TextField("Username", text: $settingsViewModel.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $settingsViewModel.password)
                        .textContentType(.password)
                }

                Section("Connection") {
                    if settingsViewModel.isTesting {
                        HStack {
                            ProgressView()
                            Text("Testing connection...")
                        }
                    } else {
                        Button {
                            Task {
                                await settingsViewModel.testConnection()
                                let status = await StorytellerActor.shared.connectionStatus
                                if status == .connected {
                                    let _ = await StorytellerActor.shared.fetchLibraryInformation()
                                }
                                await mediaViewModel.refreshMetadata(source: "TVSettingsView")
                            }
                        } label: {
                            Label(
                                isConnected ? "Reconnect" : "Connect",
                                systemImage: "network"
                            )
                        }
                    }

                    if isConnected {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                        }
                    }

                    if let error = settingsViewModel.connectionError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if isConnected {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await settingsViewModel.logout()
                            }
                        } label: {
                            Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
