#if os(iOS)
import CarPlay
import SilveranKitCommon
import SilveranKitSwiftUI
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var isLoadingBook = false
    private var readalongListTemplate: CPListTemplate?
    private var audiobookListTemplate: CPListTemplate?
    private var lastKnownBookId: String?
    private var lastKnownIsPlaying: Bool = false

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        debugLog("[CarPlay] Connected to CarPlay")
        self.interfaceController = interfaceController

        configureNowPlayingTemplate()

        Task { @MainActor in
            await setupAndShowRootTemplate()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        debugLog("[CarPlay] Disconnected from CarPlay")
        self.interfaceController = nil
        Task { @MainActor in
            CarPlayCoordinator.shared.onLibraryUpdated = nil
            CarPlayCoordinator.shared.onChaptersUpdated = nil
        }
    }

    @MainActor
    private func setupAndShowRootTemplate() async {
        let coordinator = CarPlayCoordinator.shared

        coordinator.onLibraryUpdated = { [weak self] in
            debugLog("[CarPlay] Library updated, refreshing list contents")
            Task { @MainActor in
                await self?.refreshListTemplates()
            }
        }

        coordinator.onPlaybackStateChanged = { [weak self] in
            Task { @MainActor in
                await self?.refreshListTemplatesIfNeeded()
            }
        }

        let tabBar = await buildTabBarTemplate()
        interfaceController?.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    @MainActor
    private func refreshListTemplatesIfNeeded() async {
        let coordinator = CarPlayCoordinator.shared
        let currentBookId = coordinator.activeBookId
        let currentIsPlaying = coordinator.isPlaying

        guard currentBookId != lastKnownBookId || currentIsPlaying != lastKnownIsPlaying else {
            return
        }

        lastKnownBookId = currentBookId
        lastKnownIsPlaying = currentIsPlaying
        await refreshListTemplates()
    }

    @MainActor
    private func refreshListTemplates() async {
        if let readalongTemplate = readalongListTemplate {
            let sections = await buildListSections(category: .synced)
            readalongTemplate.updateSections(sections)
        }
        if let audiobookTemplate = audiobookListTemplate {
            let sections = await buildListSections(category: .audio)
            audiobookTemplate.updateSections(sections)
        }
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
                    debugLog(
                        "[CarPlay] Chapter selected: \(chapter.label), sectionIndex: \(chapter.sectionIndex)"
                    )
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

    @MainActor
    private func buildTabBarTemplate() async -> CPTabBarTemplate {
        let readalongTab = await buildListTemplate(
            title: "Readalongs",
            category: .synced,
            systemImage: "book.and.wrench"
        )
        readalongListTemplate = readalongTab

        let audiobooksTab = await buildListTemplate(
            title: "Audiobooks",
            category: .audio,
            systemImage: "headphones"
        )
        audiobookListTemplate = audiobooksTab

        return CPTabBarTemplate(templates: [readalongTab, audiobooksTab])
    }

    @MainActor
    private func buildListSections(category: LocalMediaCategory) async -> [CPListSection] {
        let coordinator = CarPlayCoordinator.shared
        let downloadedBooks = await coordinator.getDownloadedBooks(category: category)

        var items: [CPListItem] = []
        for book in downloadedBooks {
            let coverImage = await coordinator.getCoverImage(for: book.id)
            let resizedCover =
                coverImage.map { resizeCoverImage($0) } ?? UIImage(systemName: "book.closed.fill")

            let isCurrentBook = coordinator.isBookCurrentlyLoaded(book.uuid)
            let isPlaying = coordinator.isBookCurrentlyPlaying(book.uuid)

            let item = CPListItem(
                text: book.title,
                detailText: isCurrentBook
                    ? (isPlaying ? "Now Playing" : "Paused") : book.authors?.first?.name,
                image: resizedCover
            )
            item.handler = { [weak self] _, completion in
                self?.handleBookSelection(book, category: category, completion: completion)
            }
            item.isPlaying = isPlaying
            item.accessoryType = .disclosureIndicator
            items.append(item)
        }

        return [CPListSection(items: items)]
    }

    @MainActor
    private func buildListTemplate(
        title: String,
        category: LocalMediaCategory,
        systemImage: String
    ) async -> CPListTemplate {
        let sections = await buildListSections(category: category)
        let template = CPListTemplate(title: title, sections: sections)
        template.tabImage = UIImage(systemName: systemImage)

        if sections.first?.items.isEmpty == true {
            template.emptyViewTitleVariants = ["No Downloaded \(title)"]
            template.emptyViewSubtitleVariants = ["Download books on your iPhone first"]
        }

        return template
    }

    private func resizeCoverImage(_ image: UIImage) -> UIImage {
        let targetSize = CGSize(width: 80, height: 80)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func handleBookSelection(
        _ book: BookMetadata,
        category: LocalMediaCategory,
        completion: @escaping () -> Void
    ) {
        let coordinator = CarPlayCoordinator.shared

        Task { @MainActor in
            let actualLoadedBookId = await SMILPlayerActor.shared.getLoadedBookId()
            let isActuallyLoaded = actualLoadedBookId == book.uuid

            if isActuallyLoaded {
                debugLog(
                    "[CarPlay] Book actually loaded in actor, navigating to NowPlaying: \(book.title)"
                )

                if !coordinator.isPlaying {
                    debugLog("[CarPlay] Book is paused, resuming playback")
                    try? await SMILPlayerActor.shared.play()
                }

                let nowPlayingTemplate = CPNowPlayingTemplate.shared
                self.interfaceController?.pushTemplate(nowPlayingTemplate, animated: true) {
                    success,
                    error in
                    if let error = error {
                        debugLog("[CarPlay] Failed to push NowPlayingTemplate: \(error)")
                    } else {
                        debugLog("[CarPlay] NowPlayingTemplate pushed: \(success)")
                    }
                }
                completion()
                return
            }

            await self.loadNewBook(book, category: category, completion: completion)
        }
    }

    @MainActor
    private func loadNewBook(
        _ book: BookMetadata,
        category: LocalMediaCategory,
        completion: @escaping () -> Void
    ) async {
        guard !isLoadingBook else {
            debugLog("[CarPlay] Already loading a book, ignoring selection")
            completion()
            return
        }

        debugLog("[CarPlay] Loading new book: \(book.title), category: \(category)")
        isLoadingBook = true
        defer { isLoadingBook = false }

        do {
            try await CarPlayCoordinator.shared.loadAndPlayBook(book, category: category)
            debugLog("[CarPlay] Book loaded successfully, pushing NowPlayingTemplate")

            let nowPlayingTemplate = CPNowPlayingTemplate.shared
            interfaceController?.pushTemplate(nowPlayingTemplate, animated: true) {
                success,
                error in
                if let error = error {
                    debugLog("[CarPlay] Failed to push NowPlayingTemplate: \(error)")
                } else {
                    debugLog("[CarPlay] NowPlayingTemplate pushed: \(success)")
                }
            }
        } catch {
            debugLog("[CarPlay] Failed to load book: \(error)")
        }

        completion()
    }
}
#endif
