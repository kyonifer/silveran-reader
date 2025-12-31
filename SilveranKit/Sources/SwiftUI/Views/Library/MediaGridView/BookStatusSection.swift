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
        mediaViewModel.availableStatuses.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
        guard mediaViewModel.connectionStatus == .connected else {
            showOfflineError = true
            selectedStatusName = currentItem.status?.name
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let success = await StorytellerActor.shared.updateStatus(
            forBooks: [item.uuid],
            toStatusNamed: statusName
        )

        if success {
            if let newStatus = mediaViewModel.availableStatuses.first(where: { $0.name == statusName }) {
                await LocalMediaActor.shared.updateBookStatus(
                    bookId: item.uuid,
                    status: newStatus
                )
            }
        } else {
            selectedStatusName = currentItem.status?.name
        }
    }
}
