#if os(iOS) || os(macOS)
import SwiftUI

struct BookStatusSection: View {
    let item: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    @State private var selectedStatusName: String?
    @State private var isUpdating = false
    @State private var showOfflineError = false

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var sortedStatuses: [BookStatus] {
        guard let sourceID = currentItem.sourceID else { return [] }
        return mediaViewModel.availableStatusesBySourceID[sourceID] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            statusPicker
        }
        .onAppear {
            selectedStatusName = currentItem.status?.name
        }
        .onChange(of: currentItem.status?.name) { _, newValue in
            selectedStatusName = newValue
        }
        .alert("Cannot Change Status", isPresented: $showOfflineError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please connect to the Storyteller server to change the book status.")
        }
    }

    @ViewBuilder
    private var statusPicker: some View {
        if sortedStatuses.isEmpty {
            Text(currentItem.status?.name ?? "Unknown")
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: $selectedStatusName) {
                ForEach(sortedStatuses, id: \.name) { status in
                    Text(status.name).tag(Optional(status.name))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(isUpdating)
            .onChange(of: selectedStatusName) { oldValue, newValue in
                guard let newValue, newValue != oldValue, oldValue != nil else { return }
                Task { await updateStatus(to: newValue) }
            }
        }
    }

    private func updateStatus(to statusName: String) async {
        let sourceID = currentItem.sourceID
        guard
            await BookServiceActor.shared.connectionStatus(sourceID: sourceID) == .connected
        else {
            showOfflineError = true
            selectedStatusName = currentItem.status?.name
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let success = await BookServiceActor.shared.updateStatus(
            forBooks: [item.uuid],
            sourceID: sourceID,
            toStatusNamed: statusName,
        )

        if !success {
            selectedStatusName = currentItem.status?.name
        }
    }
}

#endif
