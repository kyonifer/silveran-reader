import SwiftUI

enum MediaGridViewUtilities {
    #if os(macOS)
    static func nextSelectableItem(
        from direction: MoveCommandDirection,
        in items: [BookMetadata],
        currentItemID: BookMetadata.ID?,
        columnCount: Int
    ) -> BookMetadata? {
        guard !items.isEmpty else { return nil }

        let columns = max(columnCount, 1)
        let currentIndex: Int =
            if let currentItemID,
                let index = items.firstIndex(where: { $0.id == currentItemID })
            {
                index
            } else {
                -1
            }

        func clamp(_ index: Int) -> Int {
            min(max(index, 0), items.count - 1)
        }

        var targetIndex: Int?

        switch direction {
            case .up:
                if currentIndex == -1 {
                    targetIndex = clamp(0)
                } else {
                    let proposed = clamp(currentIndex - columns)
                    if proposed != currentIndex {
                        targetIndex = proposed
                    }
                }
            case .down:
                if currentIndex == -1 {
                    targetIndex = clamp(0)
                } else {
                    let proposed = clamp(currentIndex + columns)
                    if proposed != currentIndex {
                        targetIndex = proposed
                    }
                }
            case .left:
                if currentIndex == -1 {
                    targetIndex = clamp(0)
                } else if currentIndex > 0 {
                    targetIndex = clamp(currentIndex - 1)
                }
            case .right:
                if currentIndex == -1 {
                    targetIndex = clamp(0)
                } else if currentIndex < items.count - 1 {
                    targetIndex = clamp(currentIndex + 1)
                }
            default:
                break
        }

        guard let index = targetIndex, items.indices.contains(index) else { return nil }
        return items[index]
    }
    #endif

    static func mediaDownloadOptions(for item: BookMetadata) -> [MediaDownloadOption] {
        var options: [MediaDownloadOption] = []

        if item.hasAvailableEbook {
            options.append(
                .init(
                    category: .ebook,
                    title: "Ebook",
                    openTitle: "Read Ebook",
                    iconName: "book.fill"
                )
            )
        }

        if item.hasAvailableAudiobook {
            options.append(
                .init(
                    category: .audio,
                    title: "Audiobook",
                    openTitle: "Play Audiobook",
                    iconName: "headphones"
                )
            )
        }

        if item.hasAvailableReadaloud {
            options.append(
                .init(
                    category: .synced,
                    title: "Readaloud",
                    openTitle: "Read Readaloud",
                    iconName: "readalong",
                    iconType: .readaloud
                )
            )
        }

        return options
    }

    static func obviousMediaCategory(for item: BookMetadata) -> LocalMediaCategory? {
        let options = mediaDownloadOptions(for: item)
        guard !options.isEmpty else { return nil }

        if let readaloud = options.first(where: { $0.category == .synced }) {
            return readaloud.category
        }

        if options.count == 1 {
            return options[0].category
        }

        return nil
    }
}

struct MediaDownloadOption: Identifiable {
    enum IconType: Equatable {
        case system(String)
        case custom(String)
        case readaloud
    }

    let id: LocalMediaCategory
    let category: LocalMediaCategory
    let title: String
    let openTitle: String
    let iconName: String
    let iconType: IconType

    init(
        category: LocalMediaCategory,
        title: String,
        openTitle: String,
        iconName: String,
        iconType: IconType = .system("")
    ) {
        self.id = category
        self.category = category
        self.title = title
        self.openTitle = openTitle
        self.iconName = iconName
        self.iconType = iconType == .system("") ? .system(iconName) : iconType
    }

    var downloadTitle: String {
        switch category {
            case .ebook:
                "Download Ebook"
            case .audio:
                "Download Audiobook"
            case .synced:
                "Download Readaloud"
        }
    }

    var deleteTitle: String {
        switch category {
            case .ebook:
                "Delete Ebook"
            case .audio:
                "Delete Audiobook"
            case .synced:
                "Delete Readaloud"
        }
    }
}
