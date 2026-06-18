#if os(iOS)
import Foundation
import SwiftUI
import UIKit

public enum LastOpenBookStore {
    public struct Route: Codable, Equatable {
        public let bookId: String
        public let category: LocalMediaCategory
        public let openedAt: Date
        public let metadata: BookMetadata?
        public let localMediaPath: URL?
        public let localMediaRelativePath: String?

        public init(
            bookId: String,
            category: LocalMediaCategory,
            openedAt: Date,
            metadata: BookMetadata?,
            localMediaPath: URL?,
            localMediaRelativePath: String?,
        ) {
            self.bookId = bookId
            self.category = category
            self.openedAt = openedAt
            self.metadata = metadata
            self.localMediaPath = localMediaPath
            self.localMediaRelativePath = localMediaRelativePath
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bookId = try container.decode(String.self, forKey: .bookId)
            category = try container.decode(LocalMediaCategory.self, forKey: .category)
            openedAt = try container.decode(Date.self, forKey: .openedAt)
            metadata = try container.decodeIfPresent(BookMetadata.self, forKey: .metadata)
            localMediaPath = try container.decodeIfPresent(URL.self, forKey: .localMediaPath)
            localMediaRelativePath = try container.decodeIfPresent(
                String.self,
                forKey: .localMediaRelativePath,
            )
        }
    }

    private static let key = "iOSLastOpenBookRoute"

    public static var hasSavedRoute: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    static func save(bookData: PlayerBookData) async {
        let relativePath: String?
        if let localMediaPath = bookData.localMediaPath {
            relativePath = await FilesystemActor.shared.applicationSupportRelativePath(
                for: localMediaPath
            )
        } else {
            relativePath = nil
        }

        let route = Route(
            bookId: bookData.metadata.uuid,
            category: bookData.category,
            openedAt: Date(),
            metadata: bookData.metadata,
            localMediaPath: bookData.localMediaPath,
            localMediaRelativePath: relativePath,
        )
        guard let data = try? JSONEncoder().encode(route) else { return }
        UserDefaults.standard.set(data, forKey: key)
        debugLog(
            "[LastOpenBookStore] saved bookId=\(bookData.metadata.uuid) category=\(bookData.category.rawValue) relativePath=\(relativePath ?? "nil") path=\(bookData.localMediaPath?.path ?? "nil")"
        )
    }

    public static func load() -> Route? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            debugLog("[LastOpenBookStore] load: no saved route")
            return nil
        }
        guard let route = try? JSONDecoder().decode(Route.self, from: data) else {
            debugLog("[LastOpenBookStore] load: failed to decode saved route")
            return nil
        }
        debugLog(
            "[LastOpenBookStore] load: bookId=\(route.bookId) category=\(route.category.rawValue) openedAt=\(route.openedAt) hasMetadata=\(route.metadata != nil) relativePath=\(route.localMediaRelativePath ?? "nil") path=\(route.localMediaPath?.path ?? "nil")"
        )
        return route
    }

    public static func loadPlayerBookData() async -> PlayerBookData? {
        guard let route = load(),
            let metadata = route.metadata
        else { return nil }

        guard
            let localMediaPath = await FilesystemActor.shared.resolvePersistedApplicationSupportURL(
                relativePath: route.localMediaRelativePath,
                legacyAbsoluteURL: route.localMediaPath,
            )
        else { return nil }

        // coverArt is not Codable, so it is lost when the route is persisted. Reload it from
        // the on-disk cover cache, mirroring MediaItemCardView.makePlayerBookData: the primary
        // art is the audio square when an audiobook exists, otherwise the standard cover.
        let hasAudio = metadata.hasAvailableAudiobook
        let audioCover = await loadCachedCover(bookID: metadata.uuid, audio: true)
        let standardCover = await loadCachedCover(bookID: metadata.uuid, audio: false)
        // Primary art is the audio square when an audiobook exists, falling back to the
        // standard cover (and vice versa) so the player shows something when only one variant
        // was cached.
        let primaryCover = hasAudio ? (audioCover ?? standardCover) : (standardCover ?? audioCover)
        let ebookCover = hasAudio ? standardCover : nil

        return PlayerBookData(
            metadata: metadata,
            localMediaPath: localMediaPath,
            category: route.category,
            coverArt: primaryCover,
            ebookCoverArt: ebookCover,
        )
    }

    private static func loadCachedCover(bookID: String, audio: Bool) async -> Image? {
        guard let data = await BookServiceActor.shared.cachedCoverData(for: bookID, audio: audio),
            let uiImage = UIImage(data: data)
        else { return nil }
        return Image(uiImage: uiImage)
    }

    static func clearIfMatching(bookId: String, category: LocalMediaCategory) {
        guard let route = load(),
            route.bookId == bookId,
            route.category == category
        else { return }
        debugLog(
            "[LastOpenBookStore] clearIfMatching: matched bookId=\(bookId) category=\(category.rawValue)"
        )
        clear()
    }

    static func clear() {
        debugLog("[LastOpenBookStore] clear")
        UserDefaults.standard.removeObject(forKey: key)
    }
}
#endif
