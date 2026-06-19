#if os(iOS)
import SwiftUI

struct iOSReadaloudContextMenuContent: View {
    let item: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var canCreateOnServer: Bool {
        mediaViewModel.isServerBook(item.id)
    }

    private var canCreateLocally: Bool {
        mediaViewModel.isServerBook(item.id) || mediaViewModel.isLocalFolderBook(item.id)
    }

    private var readaloudStatus: String? {
        item.readaloud?.status?.uppercased()
    }

    private var isErrorOrStopped: Bool {
        readaloudStatus == "ERROR" || readaloudStatus == "STOPPED"
    }

    var body: some View {
        if item.canShowCreateReadaloud && (canCreateOnServer || canCreateLocally) {
            Menu {
                if canCreateOnServer {
                    Button {
                        startServerAlignment()
                    } label: {
                        Label("Create on Server", systemImage: "server.rack")
                    }
                }

                if canCreateLocally {
                    Button {
                        openLocalGenerator()
                    } label: {
                        Label("Create Locally", systemImage: "iphone")
                    }
                }
            } label: {
                Label("Create Readaloud", systemImage: "waveform")
            }
        }
    }

    private func startServerAlignment() {
        Task {
            _ = await BookServiceActor.shared.startAlignment(
                for: item.uuid,
                sourceID: item.sourceID,
                restart: isErrorOrStopped ? .full : .none,
            )
            await BookServiceActor.shared.fetchLibraryInformation()
        }
    }

    private func openLocalGenerator() {
        if let data = LocalReadaloudAlignmentLauncher.data(
            for: item,
            mediaViewModel: mediaViewModel,
        ) {
            NotificationCenter.default.post(name: .silveranCreateReadaloud, object: data)
        }
    }
}
#endif
