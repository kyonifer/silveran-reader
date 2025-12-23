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
                            Text("On iPhone")
                                .font(.headline)
                            Text("Control playback")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "iphone")
                            .foregroundStyle(.blue)
                    }
                }

                NavigationLink {
                    WatchLibraryView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On Watch")
                                .font(.headline)
                            Text("Offline library")
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
