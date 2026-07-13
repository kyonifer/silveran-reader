import Foundation
import Synchronization

enum AppleTemporaryFileCleaner {
    // URLSession and WatchConnectivity files are intentionally excluded because
    // background work may still need them when the app is relaunched.
    // TODO: Namespace download/model staging before cleaning bare UUIDs, and reconcile
    // outstanding transfers before cleaning watch_chunks_* or <uuid>_book.<ext> files.
    private static let ownedNames: Set<String> = [
        "SilveranBookServiceUploads",
        "SilveranFolderSourceDownloads",
        "SilveranReadaloudGeneratorInputs",
        "silveran-content-server",
    ]
    private static let cleanupState = Mutex(false)

    static func cleanAbandonedFilesOnce(
        in temporaryDirectory: URL,
        fileManager: FileManager = .default,
    ) {
        let shouldClean = cleanupState.withLock { didClean in
            guard !didClean else { return false }
            didClean = true
            return true
        }
        guard shouldClean else { return }
        cleanAbandonedFiles(in: temporaryDirectory, fileManager: fileManager)
    }

    static func cleanAbandonedFiles(
        in temporaryDirectory: URL,
        fileManager: FileManager = .default,
    ) {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
        else { return }

        for entry in entries where isOwned(entry.lastPathComponent) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func isOwned(_ name: String) -> Bool {
        if ownedNames.contains(name) {
            return true
        }
        if name.hasPrefix("smil_audio_") {
            let suffix = name.dropFirst("smil_audio_".count)
            if let extensionSeparator = suffix.firstIndex(of: ".") {
                return UUID(uuidString: String(suffix[..<extensionSeparator])) != nil
            }
        }
        if name.hasPrefix("story_align_") {
            let token = name.dropFirst("story_align_".count)
            return token.count == 12
                && UUID(uuidString: "\(token)0-0000-0000-000000000000") != nil
        }
        return false
    }
}
