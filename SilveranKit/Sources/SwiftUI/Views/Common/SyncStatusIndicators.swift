import SwiftUI

struct SyncStatusIndicators: View {
    let bookId: String
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var iCloudEnabled: Bool = true
    @State private var storytellerConfigured: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if storytellerConfigured {
                storytellerIndicator
            }
            if iCloudEnabled {
                iCloudIndicator
            }
        }
        .task {
            iCloudEnabled = await SettingsActor.shared.config.sync.iCloudSyncEnabled
            storytellerConfigured = await StorytellerActor.shared.isConfigured
        }
    }

    private var pendingSync: PendingProgressSync? {
        mediaViewModel.pendingSyncsByBook[bookId]
    }

    private var storytellerSynced: Bool {
        guard let pending = pendingSync else { return true }
        return pending.syncedToStoryteller
    }

    private var iCloudSynced: Bool {
        guard let pending = pendingSync else { return true }
        return pending.syncedToCloudKit
    }

    private var storytellerIndicator: some View {
        Image(systemName: "server.rack")
            .font(.system(size: 12))
            .foregroundStyle(storytellerSynced ? .green : .orange)
            .help(storytellerSynced ? "Synced to Storyteller" : "Pending sync to Storyteller")
    }

    private var iCloudIndicator: some View {
        Image(systemName: iCloudSynced ? "icloud.fill" : "icloud")
            .font(.system(size: 12))
            .foregroundStyle(iCloudSynced ? .green : .orange)
            .help(iCloudSynced ? "Synced to iCloud" : "Pending sync to iCloud")
    }
}
