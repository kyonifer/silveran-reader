#if os(macOS)
import AppKit
import Foundation
import SilveranKitAppModel

@MainActor
enum LocalReadaloudAlignmentLauncher {
    static func data(
        for item: BookMetadata,
        mediaViewModel: MediaViewModel,
    ) -> ReadaloudGeneratorData? {
        let ebookURL = mediaViewModel.localMediaPath(for: item.id, category: .ebook)
        let audioURL = mediaViewModel.localMediaPath(for: item.id, category: .audio)
            .flatMap(resolveAudioURL)

        return ReadaloudGeneratorData(
            bookID: item.id,
            bookTitle: item.title,
            sourceID: item.sourceID,
            sourceName: item.source ?? "source",
            sourceKind: mediaViewModel.isLocalFolderBook(item.id)
                ? .localFolder
                : (mediaViewModel.isServerBook(item.id) ? .storyteller : nil),
            destination: .source,
            ebookURL: ebookURL,
            audioURL: audioURL,
        )
    }

    private static func resolveAudioURL(_ url: URL) -> URL? {
        guard url.lastPathComponent == "manifest.json" else { return url }

        struct Manifest: Decodable {
            let readingOrder: [ReadingOrderItem]
        }

        struct ReadingOrderItem: Decodable {
            let href: String
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard let href = manifest.readingOrder.first?.href else { return nil }
            let audioURL = url.deletingLastPathComponent().appendingPathComponent(href)
            return FileManager.default.fileExists(atPath: audioURL.path) ? audioURL : nil
        } catch {
            debugLog("[LocalReadaloudAlignmentLauncher] Failed to resolve audiobook manifest: \(error)")
            return nil
        }
    }

}
#endif
