import Foundation

private actor SilveranMigrationState {
    static let shared = SilveranMigrationState()

    private var migrationTask: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let migrationTask {
            await migrationTask.value
            return
        }

        let task = Task {
            await operation()
        }
        migrationTask = task
        await task.value
    }
}

public enum SilveranMigrations {
    public static func runMigrations() async {
        await SilveranMigrationState.shared.run {
            await runMigrationList()
        }
    }

    public static func ensureMigrationsRan() async {
        await runMigrations()
    }

    private static func runMigrationList() async {
        let filesystem = FilesystemActor.shared
        let sources = await runBookSourceRegistryMigration(using: filesystem)
        await runCredentialMigrations(using: filesystem, sources: sources)
        await runPendingProgressQueueMigrations(using: filesystem)
        await runStorageMigrations(using: filesystem, sources: sources)
        await filesystem.runLegacyLocalProgressMigrationIfNeeded(sources: sources)
    }

    private static func runBookSourceRegistryMigration(
        using filesystem: FilesystemActor
    ) async -> [BookSourceRecord] {
        do {
            if let sources = try await filesystem.loadBookSources(), !sources.isEmpty {
                return sources
            }

            return try await filesystem.migrateLegacyBookSourceRegistry()
        } catch {
            debugLog("[SilveranMigrations] Book source registry migration failed: \(error)")
            return []
        }
    }

    private static func runStorageMigrations(
        using filesystem: FilesystemActor,
        sources: [BookSourceRecord],
    ) async {
        guard !sources.isEmpty else { return }

        do {
            try await filesystem.runStorageMigrations(for: sources)
        } catch {
            debugLog("[SilveranMigrations] Storage migration failed: \(error)")
        }
    }

    private static func runPendingProgressQueueMigrations(
        using filesystem: FilesystemActor
    ) async {
        do {
            try await filesystem.runPendingProgressQueueMigrations()
        } catch {
            debugLog("[SilveranMigrations] Pending progress queue migration failed: \(error)")
        }
    }

    private static func runCredentialMigrations(
        using filesystem: FilesystemActor,
        sources: [BookSourceRecord],
    ) async {
        guard !sources.isEmpty else { return }

        do {
            try await filesystem.runLegacyCredentialMigrations(for: sources)
        } catch {
            debugLog("[SilveranMigrations] Credential migration failed: \(error)")
        }
    }
}
