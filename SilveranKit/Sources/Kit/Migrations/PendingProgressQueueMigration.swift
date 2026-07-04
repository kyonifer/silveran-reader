import Foundation

extension FilesystemActor {
    private static let pendingProgressSourceIDMigrationID = "pending-progress-source-id-v1"

    func runPendingProgressQueueMigrations() async throws {
        try await purgeLegacyPendingProgressWithoutSourceIDIfNeeded()
    }

    private func purgeLegacyPendingProgressWithoutSourceIDIfNeeded() async throws {
        guard !migrationSentinelExists(Self.pendingProgressSourceIDMigrationID) else { return }

        let queue = try await loadProgressQueue()
        let filtered = queue.filter { $0.sourceID != nil }

        if filtered.count != queue.count {
            try await saveProgressQueue(filtered)
            debugLog(
                "[FilesystemActor] Purged \(queue.count - filtered.count) legacy pending progress item(s) without sourceID"
            )
        }

        try writeMigrationSentinel(Self.pendingProgressSourceIDMigrationID)
    }
}
