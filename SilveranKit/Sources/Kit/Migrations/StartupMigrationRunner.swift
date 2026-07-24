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
            do {
                try await filesystem.runFlatColorThemeMigrationIfNeeded()
            } catch {
                debugLog("[SilveranMigrations] Flat color theme migration deferred: \(error)")
            }
            let sources = try await runBookSourceRegistryMigration(using: filesystem)
            await runCredentialMigrations(using: filesystem, sources: sources)
            await runKeychainAccessibilityMigrations(using: filesystem, sources: sources)
            try await filesystem.prepareBookIdentityMigrationBeforeStorage(for: sources)
            try await filesystem.runStorageMigrations(for: sources)
            #if os(watchOS)
            let identitySources = try await filesystem.watchIdentityMigrationSources(
                including: sources
            )
            #else
            let identitySources = sources
            #endif
            try await filesystem.runBookIdentityMigration(for: identitySources)
            do {
                try await filesystem.runBookHighlightsMigration(for: identitySources)
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

#if os(watchOS)
extension FilesystemActor {
    fileprivate func watchIdentityMigrationSources(
        including registeredSources: [BookSourceRecord]
    ) throws -> [BookSourceRecord] {
        guard
            !migrationSentinelExists(BookIdentityMigration.sentinelName)
                || !migrationSentinelExists(BookHighlightsMigration.sentinelName)
        else { return registeredSources }

        let registeredIDs = Set(registeredSources.map(\.id))
        let discoveredIDs = try sourceCacheSourceIDs().subtracting(registeredIDs)
        let discovered = discoveredIDs.sorted().map { sourceID in
            BookSourceRecord(
                id: sourceID,
                name: "Sideloaded from iPhone",
                kind: .storyteller,
                capabilities: .storyteller,
            )
        }
        return registeredSources + discovered
    }
}
#endif
