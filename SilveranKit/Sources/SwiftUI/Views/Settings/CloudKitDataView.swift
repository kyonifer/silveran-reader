import SwiftUI

public struct CloudKitDataView: View {
    @State private var records: [CloudKitRecordInfo] = []
    @State private var isLoading = true
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading CloudKit data...")
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.icloud",
                    description: Text(error)
                )
            } else if records.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "icloud",
                    description: Text("No reading positions are synced to iCloud")
                )
            } else {
                recordsList
            }
        }
        .navigationTitle("iCloud Data")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear All iCloud Data?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task {
                    await clearAllRecords()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all \(records.count) reading position\(records.count == 1 ? "" : "s") stored in iCloud. This cannot be undone.")
        }
        .task {
            await loadRecords()
        }
        .refreshable {
            await loadRecords()
        }
    }

    private var recordsList: some View {
        List {
            Section {
                ForEach(records) { record in
                    CloudKitRecordRow(record: record)
                }
                .onDelete { indexSet in
                    Task {
                        await deleteRecords(at: indexSet)
                    }
                }
            } header: {
                Text("\(records.count) position\(records.count == 1 ? "" : "s") synced")
            } footer: {
                Text("Swipe left to delete individual records")
            }
        }
    }

    private func loadRecords() async {
        isLoading = true
        errorMessage = nil

        let cloudKitStatus = await CloudKitSyncActor.shared.connectionStatus
        guard cloudKitStatus == .connected else {
            errorMessage = "Not connected to iCloud"
            isLoading = false
            return
        }

        guard let progress = await CloudKitSyncActor.shared.fetchAllProgress() else {
            errorMessage = "Failed to fetch records"
            isLoading = false
            return
        }

        let storytellerMetadata = await LocalMediaActor.shared.localStorytellerMetadata
        let standaloneMetadata = await LocalMediaActor.shared.localStandaloneMetadata
        let allMetadata = storytellerMetadata + standaloneMetadata

        var infos: [CloudKitRecordInfo] = []
        for (bookId, cloudKitProgress) in progress {
            let bookTitle = allMetadata.first { $0.uuid == bookId }?.title ?? "Unknown Book"
            let info = CloudKitRecordInfo(
                bookId: bookId,
                bookTitle: bookTitle,
                timestamp: cloudKitProgress.timestamp,
                deviceId: cloudKitProgress.deviceId,
                progressFraction: cloudKitProgress.locator.locations?.totalProgression
                    ?? cloudKitProgress.locator.locations?.progression
            )
            infos.append(info)
        }

        records = infos.sorted { $0.timestamp > $1.timestamp }
        isLoading = false
    }

    private func clearAllRecords() async {
        isLoading = true
        let _ = await CloudKitSyncActor.shared.deleteAllRecords()
        await loadRecords()
    }

    private func deleteRecords(at indexSet: IndexSet) async {
        for index in indexSet {
            let record = records[index]
            let _ = await CloudKitSyncActor.shared.deleteProgress(for: record.bookId)
        }
        await loadRecords()
    }
}

private struct CloudKitRecordInfo: Identifiable {
    let bookId: String
    let bookTitle: String
    let timestamp: Double
    let deviceId: String
    let progressFraction: Double?

    var id: String { bookId }

    var lastSyncDate: Date {
        Date(timeIntervalSince1970: timestamp / 1000)
    }

    var formattedProgress: String? {
        guard let progress = progressFraction else { return nil }
        return String(format: "%.0f%%", progress * 100)
    }
}

private struct CloudKitRecordRow: View {
    let record: CloudKitRecordInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.bookTitle)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 12) {
                if let progress = record.formattedProgress {
                    Label(progress, systemImage: "book")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(record.lastSyncDate, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("From: \(record.deviceId)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        CloudKitDataView()
    }
}
