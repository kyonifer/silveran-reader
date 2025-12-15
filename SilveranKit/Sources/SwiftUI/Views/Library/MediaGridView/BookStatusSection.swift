import SwiftUI

struct BookStatusSection: View {
    let item: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    @State private var selectedStatusUUID: String?
    @State private var isUpdating = false
    @State private var showOfflineError = false

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var availableStatuses: [BookStatus] {
        var unique: [String: BookStatus] = [:]
        for book in mediaViewModel.library.bookMetaData {
            guard let status = book.status, let uuid = status.uuid else { continue }
            if unique[uuid] == nil {
                unique[uuid] = status
            }
        }
        return unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            selectedStatusUUID = currentItem.status?.uuid
        }
        .onChange(of: currentItem.status?.uuid) { _, newValue in
            selectedStatusUUID = newValue
        }
        .alert("Cannot Change Status", isPresented: $showOfflineError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please connect to the Storyteller server to change the book status.")
        }
    }

    @ViewBuilder
    private var statusPicker: some View {
        if availableStatuses.isEmpty {
            Text(currentItem.status?.name ?? "Unknown")
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: $selectedStatusUUID) {
                ForEach(availableStatuses, id: \.uuid) { status in
                    Text(status.name).tag(status.uuid)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(isUpdating)
            .onChange(of: selectedStatusUUID) { oldValue, newValue in
                guard let newValue, newValue != oldValue, oldValue != nil else { return }
                Task { await updateStatus(to: newValue) }
            }
        }
    }

    private func updateStatus(to statusUUID: String) async {
        guard mediaViewModel.connectionStatus == .connected else {
            showOfflineError = true
            selectedStatusUUID = currentItem.status?.uuid
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let success = await StorytellerActor.shared.updateStatus(
            forBooks: [item.uuid],
            to: statusUUID
        )

        if success {
            if let newStatus = availableStatuses.first(where: { $0.uuid == statusUUID }) {
                await LocalMediaActor.shared.updateBookStatus(
                    bookId: item.uuid,
                    status: newStatus
                )
            }
        } else {
            selectedStatusUUID = currentItem.status?.uuid
        }
    }
}
