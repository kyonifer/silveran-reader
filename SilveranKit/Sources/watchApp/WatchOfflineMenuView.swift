#if os(watchOS)
import SwiftUI

struct WatchOfflineMenuView: View {
    @Environment(WatchViewModel.self) private var viewModel
    @State private var showSettingsView = false

    var body: some View {
        List {
            NavigationLink {
                WatchLibraryView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Available Books")
                            .font(.caption)
                        Text("\(viewModel.books.count) downloaded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.blue)
                }
            }

            NavigationLink {
                WatchDownloadMenuView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server Download")
                            .font(.caption)
                        Text("Browse Storyteller")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.green)
                }
            }

            NavigationLink {
                WatchTransferInstructionsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhone Transfer")
                            .font(.caption)
                        Text("Send via iPhone app")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.and.arrow.right.outward")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("On Watch")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettingsView = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettingsView) {
            WatchSettingsView()
        }
    }
}

struct WatchDownloadMenuView: View {
    var body: some View {
        List {
            NavigationLink {
                WatchCurrentlyReadingView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Currently Reading")
                            .font(.caption)
                        Text("Books in progress")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "book")
                        .foregroundStyle(.blue)
                }
            }

            NavigationLink {
                WatchAllBooksView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Books")
                            .font(.caption)
                        Text("Full library")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.purple)
                }
            }
        }
        .navigationTitle("Download")
    }
}

struct WatchTransferInstructionsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "iphone.badge.play")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)

                Text("Transfer from iPhone")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    InstructionRow(number: 1, text: "Open Silveran Reader on iPhone")
                    InstructionRow(number: 2, text: "Go to More tab")
                    InstructionRow(number: 3, text: "Tap Apple Watch")
                    InstructionRow(number: 4, text: "Tap + to select a book")
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Text("Books transfer in the background, even when the watch screen is off.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Transfer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.orange))

            Text(text)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    WatchOfflineMenuView()
}
#endif
