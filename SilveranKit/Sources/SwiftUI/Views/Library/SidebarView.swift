import SwiftUI

struct SidebarView: View {
    let sections: [SidebarSectionDescription]
    @Binding var selectedItem: SidebarItemDescription?
    @Binding var searchText: String
    @Binding var isSearchFocused: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var selectedUuid: UUID?
    @State private var isRefreshing: Bool = false

    private var storytellerConfigured: Bool {
        mediaViewModel.connectionStatus != .disconnected
    }

    var body: some View {
        List(selection: $selectedUuid) {
            ForEach(sections) { section in
                Section {
                    OutlineGroup(section.items, children: \.children) { item in
                        HStack {
                            Label(item.name, systemImage: item.systemImage)
                                .tag(item.id)
                            Spacer()

                            if item.name == "Storyteller Server" {
                                connectionIndicator(for: mediaViewModel.connectionStatus)
                            } else {
                                let count = mediaViewModel.badgeCount(for: item.content)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(section.name)
                            .font(.headline)
                        #if os(macOS)
                        if section.name == "Library" && storytellerConfigured {
                            Spacer()
                            Button {
                                Task { await refreshMetadata() }
                            } label: {
                                if isRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 11))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(isRefreshing)
                        }
                        #endif
                    }
                    .padding(.bottom, 3)
                    .padding(.trailing, 16)
                }
            }
        }
        .onChange(of: selectedUuid) { oldID, newID in
            if let id = newID {
                selectedItem = findItem(by: id)
            } else {
                selectedItem = nil
            }
        }
        .onChange(of: selectedItem) { oldItem, newItem in
            selectedUuid = newItem?.id
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchFocused,
            placement: .sidebar,
            prompt: "Search"
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 250)
    }

    private func findItem(by id: UUID) -> SidebarItemDescription? {
        for section in sections {
            for item in section.items {
                if item.id == id { return item }
                for child in item.children ?? [] {
                    if child.id == id { return child }
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func connectionIndicator(for status: ConnectionStatus) -> some View {
        switch status {
            case .connected:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            case .disconnected:
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
            case .error:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
        }
    }

    #if os(macOS)
    private func refreshMetadata() async {
        isRefreshing = true

        if let library = await StorytellerActor.shared.fetchLibraryInformation() {
            do {
                try await LocalMediaActor.shared.updateStorytellerMetadata(library)
                await mediaViewModel.refreshMetadata(source: "SidebarView.refresh")
                mediaViewModel.showSyncNotification(
                    SyncNotification(message: "Library refreshed", type: .success)
                )
            } catch {
                mediaViewModel.showSyncNotification(
                    SyncNotification(message: "Failed to update metadata", type: .error)
                )
            }
        } else {
            mediaViewModel.showSyncNotification(
                SyncNotification(message: "Failed to fetch metadata from server", type: .error)
            )
        }

        isRefreshing = false
    }
    #endif
}
