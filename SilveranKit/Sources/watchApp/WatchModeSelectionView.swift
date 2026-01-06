import SwiftUI

struct WatchModeSelectionView: View {
    @Environment(WatchViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    WatchRemoteControlView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remote Control")
                                .font(.headline)
                            Text("Of iPhone")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "iphone")
                            .foregroundStyle(.blue)
                    }
                }

                NavigationLink {
                    WatchOfflineMenuView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Playback")
                                .font(.headline)
                            Text("On Watch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "applewatch")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Silveran")
        }
    }
}
