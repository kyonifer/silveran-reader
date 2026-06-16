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
        let standardCoverState = mediaViewModel.coverState(for: item, variant: .standard)
        let audioCoverState = mediaViewModel.coverState(for: item, variant: .audioSquare)
        let shouldRenderDoubleCover =
            isDoubleCover && standardCoverState.image != nil && audioCoverState.image != nil
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
                        cornerRadius: 6,
                        isSwapping: .constant(false),
                    )
                    .frame(width: tileSize, height: tileSize / aspectRatio)
                } else {
                    ZStack {
                        if displayImage == nil {
                            placeholderColor
                        }
                        if let image = displayImage {
                            image
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                        }
                    }
                    .frame(width: tileSize, height: tileSize / aspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .stableCoverRendering()
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
                    if progressStyle == .circle {
                        CircularProgressBadge(progress: progress)
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
                if showAudioIndicator {
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
            .overlay(alignment: .top) {
                if isHovered {
                    topTabBar
                }
            }
            #endif
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
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

        var iconName: String {
            switch self {
                case .ebook: return "book.fill"
                case .audio: return "headphones"
                case .synced: return "text.bubble"
            }
        }
    }

    private var topTabBar: some View {
        HStack(spacing: 0) {
            ForEach(TabCategory.allCases, id: \.self) { tab in
                tabButton(for: tab)
            }
        }
        .frame(width: tileSize, height: 40)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func statusColor(for status: TabStatus) -> Color {
        switch status {
            case .unavailable: return .gray.opacity(0.4)
            case .availableNotDownloaded: return .blue
            case .downloaded: return .green
            case .downloading: return .blue
            case .failed: return .red
        }
    }

    @ViewBuilder
    private func tabButton(for tab: TabCategory) -> some View {
        let status = tabStatus(for: tab)
        let color = statusColor(for: status)
        let isTabHovered = hoveredTab == tab

        Button {
            handleTabTap(for: tab)
        } label: {
            ZStack {
                if case .downloading(let progress) = status {
                    DownloadCancelProgressIcon(
                        progress: progress,
                        color: color,
                        size: 24,
                        lineWidth: 2.5,
                        showsCancel: isTabHovered,
                    )
                } else if status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red)
                } else if isTabHovered && status == .availableNotDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24))
                } else if isTabHovered && status == .downloaded {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                } else if tab == .synced {
                    ReadaloudIcon(size: 26)
                } else {
                    Image(systemName: tab.iconName)
                        .font(.system(size: 20))
                }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .unavailable)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
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
