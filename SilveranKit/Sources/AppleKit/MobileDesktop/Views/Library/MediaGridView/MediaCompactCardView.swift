#if os(iOS) || os(macOS)
import SwiftUI

struct MediaCompactCardView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    let coverPreference: CoverPreference
    let tileSize: CGFloat
    let showAudioIndicator: Bool
    let sourceLabel: String?
    let seriesPositionBadge: String?
    let progressStyle: ProgressIndicatorStyle
    let isSelected: Bool
    let onSelect: (BookMetadata) -> Void
    let onInfo: (BookMetadata) -> Void
    var onEditMetadata: (([String]) -> Void)? = nil
    @Environment(MediaViewModel.self) private var mediaViewModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false
    @State private var hoveredTab: TabCategory?
    #endif
    private let availableMediaColor = Color.gray.opacity(0.72)
    #if os(iOS)
    @Environment(\.mediaNavigationPath) private var mediaNavigationPath
    @Environment(\.editMetadataAction) private var editMetadataAction
    @State private var pendingDetailsNavigation = false
    #endif

    var body: some View {
        #if os(iOS)
        if let playerData = preferredPlayerBookData {
            NavigationLink(value: playerData) {
                cardContent
            }
            .buttonStyle(.plain)
            .background(deferredNavigationLinks)
            .contextMenu { iOSContextMenu }
        } else {
            NavigationLink(value: item) {
                cardContent
            }
            .buttonStyle(.plain)
            .background(deferredNavigationLinks)
            .contextMenu { iOSContextMenu }
        }
        #else
        cardContent
        #endif
    }

    private var isDoubleCover: Bool {
        coverPreference == .storytellerDouble
    }

    private var cardContent: some View {
        let coverVariant = resolveCoverVariant(for: item)
        let aspectRatio = coverPreference.preferredContainerAspectRatio
        let coverState = mediaViewModel.coverState(for: item, variant: coverVariant)
        let fallbackVariant: MediaViewModel.CoverVariant =
            coverVariant == .standard ? .audioSquare : .standard
        let fallbackState = mediaViewModel.coverState(for: item, variant: fallbackVariant)
        let displayImage = coverState.image ?? fallbackState.image
        let shownVariant: MediaViewModel.CoverVariant =
            coverState.image == nil && fallbackState.image != nil ? fallbackVariant : coverVariant
        let shouldRenderDoubleCover =
            isDoubleCover
            && ((item.hasAvailableEbook && item.hasAvailableAudiobook)
                || item.hasAvailableReadaloud)
        let placeholderColor = Color(white: 0.2)
        let progress = mediaViewModel.progress(for: item.id)

        return VStack(spacing: 0) {
            Group {
                if shouldRenderDoubleCover {
                    DoubleCoverView(
                        item: item,
                        placeholderColor: placeholderColor,
                        coverWidth: tileSize,
                        containerAspectRatio: aspectRatio,
                        cornerRadius: 8,
                        isSwapping: .constant(false),
                        showReadaloudWedge: showAudioIndicator && item.hasAvailableReadaloud,
                        notchProgress: (progressStyle == .circle && progress > 0) ? progress : nil,
                    )
                    .frame(width: tileSize, height: tileSize / aspectRatio)
                } else {
                    RoundedCoverArtwork(
                        image: displayImage,
                        placeholderColor: placeholderColor,
                        variant: shownVariant,
                        cornerRadius: 8,
                    )
                    .frame(width: tileSize, height: tileSize / shownVariant.displayAspectRatio)
                }
            }
            .stableCoverRendering()
            .overlay(alignment: .bottom) {
                if progressStyle == .line && progress > 0 {
                    GeometryReader { geometry in
                        let clamped = min(max(progress, 0), 1)
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.tint.opacity(0.3))
                            Rectangle()
                                .fill(.tint)
                                .frame(width: geometry.size.width * CGFloat(clamped))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if progress > 0 {
                    if progressStyle == .circle && !shouldRenderDoubleCover {
                        CircularProgressBadge(progress: progress, showsBackground: true)
                            .padding(.trailing, 3)
                            .padding(.bottom, 3)
                    } else if progressStyle == .text {
                        ProgressTextBadge(progress: progress)
                            .padding(.trailing, 3)
                            .padding(.bottom, 3)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let sourceLabel = sourceLabel {
                    SourceBadge(label: sourceLabel)
                        .padding(2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showAudioIndicator && !shouldRenderDoubleCover {
                    AudioIndicatorBadge(item: item, coverVariant: coverVariant)
                        .padding(.trailing, 2)
                        .padding(.top, 2)
                }
            }
            .overlay(alignment: .topLeading) {
                if let badge = seriesPositionBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            .black.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous),
                        )
                        .padding(2)
                }
            }
            #if os(macOS)
            .overlay {
                if isHovered {
                    playOverlay
                }
            }
            #endif
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // Slot keeps a uniform row height; the cover (and its badges) center within it.
            .frame(width: tileSize, height: tileSize / aspectRatio)
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onTapGesture {
            onSelect(item)
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onInfo(item)
                }
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            BookContextMenuContent(
                item: item,
                onInfo: onInfo,
                onEditMetadata: onEditMetadata,
            )
        }
        #endif
        .task(id: coverVariant) {
            mediaViewModel.ensureCoverLoaded(for: item, variant: coverVariant)
            mediaViewModel.ensureCoverLoaded(for: item, variant: fallbackVariant)
        }
        .onDisappear {
            mediaViewModel.cancelCoverLoad(for: item, variant: coverVariant)
            mediaViewModel.cancelCoverLoad(for: item, variant: fallbackVariant)
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSContextMenu: some View {
        Button {
            handleDetailsNavigation()
        } label: {
            Label("View Details", systemImage: "info.circle")
        }

        if let editMetadataAction {
            Button {
                editMetadataAction([item.uuid])
            } label: {
                Label("Edit Metadata...", systemImage: "pencil")
            }
        }

        iOSStatusContextMenu
        iOSReadaloudContextMenuContent(item: item)
    }

    private var iOSCurrentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var iOSStatusOptions: [BookStatus] {
        guard let sourceID = iOSCurrentItem.sourceID else { return [] }
        return mediaViewModel.availableStatusesBySourceID[sourceID] ?? []
    }

    @ViewBuilder
    private var iOSStatusContextMenu: some View {
        if !iOSStatusOptions.isEmpty {
            Menu {
                ForEach(iOSStatusOptions, id: \.name) { status in
                    Button {
                        setStatus(status.name)
                    } label: {
                        if status.name == iOSCurrentItem.status?.name {
                            Label(status.name, systemImage: "checkmark")
                        } else {
                            Text(status.name)
                        }
                    }
                    .disabled(status.name == iOSCurrentItem.status?.name)
                }
            } label: {
                Label("Set Status", systemImage: "bookmark")
            }
        }
    }

    private func setStatus(_ name: String) {
        guard name != iOSCurrentItem.status?.name else { return }
        Task {
            let success = await BookServiceActor.shared.updateStatus(
                forBooks: [item.uuid],
                sourceID: iOSCurrentItem.sourceID,
                toStatusNamed: name,
            )
            if !success {
                mediaViewModel.showSyncNotification(
                    SyncNotification(
                        message: "Failed to update status",
                        type: .error,
                    )
                )
            }
        }
    }

    private func handleDetailsNavigation() {
        if let mediaNavigationPath {
            mediaNavigationPath.wrappedValue.append(item)
        } else {
            pendingDetailsNavigation = true
        }
    }

    @ViewBuilder
    private var deferredNavigationLinks: some View {
        if mediaNavigationPath == nil {
            NavigationLink(isActive: $pendingDetailsNavigation) {
                iOSBookDetailView(item: item, mediaKind: mediaKind)
            } label: {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .hidden()
        }
    }

    private var preferredPlayerBookData: PlayerBookData? {
        let settings = mediaViewModel.cachedConfig.library
        guard settings.tapToPlayPreferredPlayer else { return nil }

        let syncedDownloaded = mediaViewModel.isCategoryDownloaded(.synced, for: item)
        let audioDownloaded = mediaViewModel.isCategoryDownloaded(.audio, for: item)
        let ebookDownloaded = mediaViewModel.isCategoryDownloaded(.ebook, for: item)

        let category: LocalMediaCategory?
        if syncedDownloaded {
            category = .synced
        } else if audioDownloaded && ebookDownloaded {
            category = settings.preferAudioOverEbook ? .audio : .ebook
        } else if audioDownloaded {
            category = .audio
        } else if ebookDownloaded {
            category = .ebook
        } else {
            category = nil
        }

        guard let category else { return nil }
        let freshMetadata = mediaViewModel.library.bookMetaData.first { $0.id == item.id } ?? item
        let path = mediaViewModel.localMediaPath(for: item.id, category: category)
        let variant: MediaViewModel.CoverVariant =
            freshMetadata.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: freshMetadata, variant: variant)
        let ebookCover =
            freshMetadata.hasAvailableAudiobook
            ? mediaViewModel.coverImage(for: freshMetadata, variant: .standard)
            : nil
        return PlayerBookData(
            metadata: freshMetadata,
            localMediaPath: path,
            category: category,
            coverArt: cover,
            ebookCoverArt: ebookCover,
        )
    }
    #endif

    private func resolveCoverVariant(for item: BookMetadata) -> MediaViewModel.CoverVariant {
        mediaViewModel.coverVariant(for: item, preference: coverPreference)
    }

    #if os(macOS)
    private enum TabCategory: CaseIterable {
        case ebook, audio, synced

        var localCategory: LocalMediaCategory {
            switch self {
                case .ebook: return .ebook
                case .audio: return .audio
                case .synced: return .synced
            }
        }

        @ViewBuilder
        func iconView(size: CGFloat) -> some View {
            switch self {
                case .ebook:
                    Image("ebookIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                case .audio:
                    Image(systemName: "headphones")
                        .font(.system(size: size))
                case .synced:
                    ReadaloudIcon(size: size)
            }
        }
    }

    private enum ButtonSize {
        case large, medium, small
        var frame: CGFloat {
            switch self { case .large: 44 case .medium: 37 case .small: 30
            }
        }
        var icon: CGFloat {
            switch self { case .large: 26 case .medium: 22 case .small: 18
            }
        }
        var playIcon: CGFloat {
            switch self { case .large: 36 case .medium: 28 case .small: 24
            }
        }
    }

    private var availableTabs: [TabCategory] {
        [.ebook, .synced, .audio].filter { tabStatus(for: $0) != .unavailable }
    }

    private func buttonSize(for tab: TabCategory, in tabs: [TabCategory]) -> ButtonSize {
        let hasSynced = tabs.contains(.synced)
        switch tabs.count {
            case 1: return .large
            case 2: return hasSynced ? (tab == .synced ? .large : .small) : .medium
            default: return tab == .synced ? .large : .small
        }
    }

    private var playOverlay: some View {
        Group {
            let tabs = availableTabs
            if !tabs.isEmpty {
                let slots: [TabCategory] =
                    tabs.contains(.synced) ? [.ebook, .synced, .audio] : tabs
                HStack(spacing: 8) {
                    ForEach(slots, id: \.self) { tab in
                        let size = buttonSize(for: tab, in: tabs)
                        if tabs.contains(tab) {
                            tabButton(for: tab, size: size)
                        } else {
                            Color.clear
                                .frame(width: size.frame, height: size.frame)
                        }
                    }
                }
            }
        }
    }

    private enum TabStatus: Equatable {
        case unavailable
        case availableNotDownloaded
        case downloaded
        case downloading(progress: Double?)
        case failed
    }

    private func tabStatus(for tab: TabCategory) -> TabStatus {
        let category = tab.localCategory
        let downloading = mediaViewModel.isCategoryDownloadInProgress(
            for: item,
            category: category,
        )
        if downloading {
            let progress = mediaViewModel.downloadProgressFraction(for: item, category: category)
            return .downloading(progress: progress)
        }

        let downloaded = mediaViewModel.isCategoryDownloaded(category, for: item)
        if downloaded { return .downloaded }

        if mediaViewModel.isCategoryDownloadFailed(for: item, category: category) {
            return .failed
        }

        let available: Bool
        switch tab {
            case .ebook: available = item.hasAvailableEbook
            case .audio: available = item.hasAvailableAudiobook
            case .synced: available = item.hasAvailableReadaloud
        }

        return available ? .availableNotDownloaded : .unavailable
    }

    @ViewBuilder
    private func tabButton(for tab: TabCategory, size: ButtonSize) -> some View {
        let status = tabStatus(for: tab)
        let isTabHovered = hoveredTab == tab

        Button {
            handleTabTap(for: tab)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: size.frame, height: size.frame)
                tabIcon(for: tab, status: status, isHovered: isTabHovered, size: size)
            }
            .frame(width: size.frame, height: size.frame)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
    }

    @ViewBuilder
    private func tabIcon(
        for tab: TabCategory,
        status: TabStatus,
        isHovered: Bool,
        size: ButtonSize,
    ) -> some View {
        if case .downloading(let progress) = status {
            DownloadCancelProgressIcon(
                progress: progress,
                color: .white,
                size: size.icon,
                lineWidth: 2.5,
                showsCancel: isHovered,
            )
        } else if status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size.icon))
                .foregroundStyle(.red)
        } else if isHovered && status == .availableNotDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size.playIcon))
                .foregroundStyle(.white)
        } else if isHovered && status == .downloaded {
            Image(systemName: "play.circle.fill")
                .font(.system(size: size.playIcon))
                .foregroundStyle(.white)
        } else {
            tab.iconView(size: size.icon)
                .foregroundStyle(
                    status == .downloaded
                        ? AnyShapeStyle(Color.white) : AnyShapeStyle(availableMediaColor)
                )
        }
    }

    private func handleTabTap(for tab: TabCategory) {
        let category = tab.localCategory
        let status = tabStatus(for: tab)

        if case .downloading = status {
            mediaViewModel.cancelDownload(for: item, category: category)
        } else if status == .downloaded {
            openMedia(for: category)
        } else if status == .failed || status == .availableNotDownloaded {
            mediaViewModel.startDownload(for: item, category: category)
        }
    }

    private func openMedia(for category: LocalMediaCategory) {
        let windowID: String
        switch category {
            case .audio:
                windowID = "AudiobookPlayer"
            case .ebook, .synced:
                windowID = "EbookPlayer"
        }
        let path = mediaViewModel.localMediaPath(for: item.id, category: category)
        let variant: MediaViewModel.CoverVariant =
            item.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: item, variant: variant)
        let ebookCover =
            item.hasAvailableAudiobook
            ? mediaViewModel.coverImage(for: item, variant: .standard)
            : nil
        let bookData = PlayerBookData(
            metadata: item,
            localMediaPath: path,
            category: category,
            coverArt: cover,
            ebookCoverArt: ebookCover,
        )
        openWindow(id: windowID, value: bookData)
    }
    #endif
}

#endif
