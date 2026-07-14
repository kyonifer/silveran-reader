import Foundation

actor SilveranRuntimeState {
    static let shared = SilveranRuntimeState()

    private var startupTask: Task<Bool, Never>?

    func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let startupTask {
            return await startupTask.value
        }

        let task = Task {
            await operation()
        }
        startupTask = task
        let succeeded = await task.value
        if !succeeded {
            startupTask = nil
        }
        return succeeded
    }
}

public enum SilveranRuntime {
    public static func start() async -> Bool {
        await SilveranRuntimeState.shared.run {
            guard await runMigrationList() else { return false }
            await ProgressSyncActor.shared.start()
            await BookServiceActor.shared.start()
            await LocalMediaActor.shared.start()
            await ProgressSyncActor.shared.startPolling()
            return true
        }
    }

    private static func runMigrationList() async -> Bool {
        let filesystem = FilesystemActor.shared
        do {
            let sources = try await runBookSourceRegistryMigration(using: filesystem)
            await runCredentialMigrations(using: filesystem, sources: sources)
            await runKeychainAccessibilityMigrations(using: filesystem, sources: sources)
            try await filesystem.prepareBookIdentityMigrationBeforeStorage(for: sources)
            try await filesystem.runStorageMigrations(for: sources)
            try await filesystem.runBookIdentityMigration(for: sources)
            do {
                try await filesystem.runBookHighlightsMigration(for: sources)
            } catch {
                debugLog("[SilveranMigrations] Highlight migration deferred: \(error)")
            }
            return true
        } catch {
            debugLog("[SilveranMigrations] Required startup migration failed: \(error)")
            return false
        }
    }

    private static func runBookSourceRegistryMigration(
        using filesystem: FilesystemActor
    ) async throws -> [BookSourceRecord] {
        if let sources = try await filesystem.loadBookSources(), !sources.isEmpty {
            return sources
        }

        return try await filesystem.migrateLegacyBookSourceRegistry()
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
