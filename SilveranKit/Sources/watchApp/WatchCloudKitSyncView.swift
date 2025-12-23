#if os(watchOS)
import SwiftUI
import SilveranKitCommon

struct WatchCloudKitSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lastSyncTime: Date?
    @State private var recordCount: Int = 0
    @State private var isSyncing = false
    @State private var connectionStatus: String = "Checking..."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusSection
                    syncButton
                }
                .padding()
            }
            .navigationTitle("iCloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadStatus()
        }
    }

    private var statusSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "icloud")
                    .foregroundStyle(.blue)
                Text(connectionStatus)
                    .font(.caption)
            }

            Divider()

            VStack(spacing: 4) {
                Text("\(recordCount)")
                    .font(.title2.bold())
                Text("positions synced")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let lastSync = lastSyncTime {
                VStack(spacing: 4) {
                    Text("Last sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(lastSync, format: .relative(presentation: .named))
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var syncButton: some View {
        Button {
            Task {
                await performSync()
            }
        } label: {
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(isSyncing ? "Syncing..." : "Sync")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isSyncing)
    }

    private func loadStatus() async {
        let status = await CloudKitSyncActor.shared.connectionStatus
        switch status {
            case .connected:
                connectionStatus = "Connected"
            case .disconnected:
                connectionStatus = "Disconnected"
            case .connecting:
                connectionStatus = "Connecting..."
            case .error(let message):
                connectionStatus = "Error: \(message)"
        }

        recordCount = await CloudKitSyncActor.shared.recordCount()
    }

    private func performSync() async {
        isSyncing = true

        await CloudKitSyncActor.shared.refreshConnectionStatus()

        if let progress = await CloudKitSyncActor.shared.fetchAllProgress() {
            debugLog("[WatchCloudKitSyncView] Fetched \(progress.count) positions from CloudKit")
        }

        lastSyncTime = Date()
        await loadStatus()

        isSyncing = false
    }
}

#Preview {
    WatchCloudKitSyncView()
}
#endif
