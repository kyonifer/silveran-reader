import Foundation

private actor SilveranRuntimeState {
    static let shared = SilveranRuntimeState()

    private var startupTask: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let startupTask {
            await startupTask.value
            return
        }

        let task = Task {
            await operation()
        }
        startupTask = task
        await task.value
    }
}

public enum SilveranRuntime {
    public static func start() async {
        await SilveranRuntimeState.shared.run {
            await runMigrationList()
            await ProgressSyncActor.shared.start()
            await BookServiceActor.shared.start()
            await LocalMediaActor.shared.start()
            await ProgressSyncActor.shared.startPolling()
        }
    }

    private static func runMigrationList() async {
        let filesystem = FilesystemActor.shared
        let sources = await runBookSourceRegistryMigration(using: filesystem)
        await runCredentialMigrations(using: filesystem, sources: sources)
        await runKeychainAccessibilityMigrations(using: filesystem, sources: sources)
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

    private static func runKeychainAccessibilityMigrations(
        using filesystem: FilesystemActor,
        sources: [BookSourceRecord],
    ) async {
        do {
            try await filesystem.runKeychainAccessibilityMigrations(for: sources)
        } catch {
            debugLog("[SilveranMigrations] Keychain accessibility migration failed: \(error)")
        }
    }
}
