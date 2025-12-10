#if os(iOS)
import CarPlay
import SilveranKitCommon
import SilveranKitSwiftUI
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        debugLog("[CarPlay] Connected to CarPlay")
        self.interfaceController = interfaceController
        rebuildRootTemplate()
        configureNowPlayingTemplate()

        Task { @MainActor in
            CarPlayCoordinator.shared.onMediaViewModelReady = { [weak self] in
                debugLog("[CarPlay] MediaViewModel ready, rebuilding templates")
                self?.rebuildRootTemplate()
            }

            CarPlayCoordinator.shared.onLibraryUpdated = { [weak self] in
                debugLog("[CarPlay] Library updated, rebuilding templates")
                self?.rebuildRootTemplate()
            }

            CarPlayCoordinator.shared.onChaptersUpdated = { [weak self] in
                debugLog("[CarPlay] Chapters updated")
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        debugLog("[CarPlay] Disconnected from CarPlay")
        self.interfaceController = nil
        Task { @MainActor in
            CarPlayCoordinator.shared.onMediaViewModelReady = nil
            CarPlayCoordinator.shared.onLibraryUpdated = nil
            CarPlayCoordinator.shared.onChaptersUpdated = nil
        }
    }

    private func rebuildRootTemplate() {
        let tabBar = buildTabBarTemplate()
        interfaceController?.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    private func configureNowPlayingTemplate() {
        let nowPlaying = CPNowPlayingTemplate.shared

        if let listImage = UIImage(systemName: "list.bullet") {
            let chaptersButton = CPNowPlayingImageButton(image: listImage) { [weak self] _ in
                self?.showChaptersList()
            }
            nowPlaying.updateNowPlayingButtons([chaptersButton])
        }
    }

    private func showChaptersList() {
        Task { @MainActor in
            let chapters = CarPlayCoordinator.shared.chapters
            let currentSectionIndex = CarPlayCoordinator.shared.currentChapterSectionIndex

            guard !chapters.isEmpty else {
                debugLog("[CarPlay] No chapters available")
                return
            }

            let items: [CPListItem] = chapters.map { chapter in
                let isCurrent = chapter.sectionIndex == currentSectionIndex
                let item = CPListItem(
                    text: chapter.label,
                    detailText: isCurrent ? "Now Playing" : nil
                )
                item.isPlaying = isCurrent
                item.handler = { [weak self] _, completion in
                    debugLog("[CarPlay] Chapter selected: \(chapter.label), sectionIndex: \(chapter.sectionIndex)")
                    Task { @MainActor in
                        CarPlayCoordinator.shared.selectChapter(sectionIndex: chapter.sectionIndex)
                    }
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
                return item
            }

            let section = CPListSection(items: items)
            let template = CPListTemplate(title: "Chapters", sections: [section])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func buildTabBarTemplate() -> CPTabBarTemplate {
        let readalongTab = buildListTemplate(
            title: "Readalongs",
            category: .synced,
            systemImage: "book.and.wrench"
        )
        let audiobooksTab = buildListTemplate(
            title: "Audiobooks",
            category: .audio,
            systemImage: "headphones"
        )
        return CPTabBarTemplate(templates: [readalongTab, audiobooksTab])
    }

    @MainActor
    private func buildListTemplate(
        title: String,
        category: LocalMediaCategory,
        systemImage: String
    ) -> CPListTemplate {
        guard let mediaViewModel = CarPlayCoordinator.shared.mediaViewModel else {
            let emptySection = CPListSection(items: [])
            let template = CPListTemplate(title: title, sections: [emptySection])
            template.tabImage = UIImage(systemName: systemImage)
            template.emptyViewTitleVariants = ["Open Silveran Reader"]
            template.emptyViewSubtitleVariants = ["Open the app on your iPhone once to enable CarPlay"]
            return template
        }

        let downloadedBooks = mediaViewModel.library.bookMetaData.filter { book in
            switch category {
            case .audio:
                return mediaViewModel.isCategoryDownloaded(.audio, for: book)
            case .synced:
                return mediaViewModel.isCategoryDownloaded(.synced, for: book)
            case .ebook:
                return mediaViewModel.isCategoryDownloaded(.ebook, for: book)
            }
        }.sorted { ($0.position?.updatedAt ?? "") > ($1.position?.updatedAt ?? "") }

        let items: [CPListItem] = downloadedBooks.map { book in
            let item = CPListItem(
                text: book.title,
                detailText: book.authors?.first?.name,
                image: coverImage(for: book, category: category, in: mediaViewModel)
            )
            item.handler = { [weak self] _, completion in
                self?.handleBookSelection(book, category: category)
                completion()
            }
            item.accessoryType = .disclosureIndicator
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: title, sections: [section])
        template.tabImage = UIImage(systemName: systemImage)

        if items.isEmpty {
            template.emptyViewTitleVariants = ["No Downloaded \(title)"]
            template.emptyViewSubtitleVariants = ["Download books on your iPhone first"]
        }

        return template
    }

    @MainActor
    private func coverImage(
        for book: BookMetadata,
        category: LocalMediaCategory,
        in mediaViewModel: MediaViewModel
    ) -> UIImage? {
        let audioCover = mediaViewModel.library.audiobookCoverCache[book.id].flatMap { $0?.data }
        let ebookCover = mediaViewModel.library.ebookCoverCache[book.id].flatMap { $0?.data }
        let coverData = audioCover ?? ebookCover

        guard let data = coverData, let image = UIImage(data: data) else {
            return UIImage(systemName: "book.closed.fill")
        }

        let targetSize = CGSize(width: 80, height: 80)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func handleBookSelection(_ book: BookMetadata, category: LocalMediaCategory) {
        debugLog("[CarPlay] Selected book: \(book.title), category: \(category)")

        Task { @MainActor in
            CarPlayCoordinator.shared.loadAndPlayBook(book, category: category)
        }

        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlayingTemplate, animated: true, completion: nil)
    }
}
#endif
