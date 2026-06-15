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
                if progressStyle == .circle && progress > 0 {
                    CircularProgressBadge(progress: progress)
                        .padding(.trailing, 3)
                        .padding(.bottom, 3)
                } else if progressStyle == .text && progress > 0 {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.trailing, 3)
                        .padding(.bottom, 3)
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
            .overlay {
                if isHovered {
                    playOverlay
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

    }

    private enum ButtonSize {
        case large, medium, small
        var frame: CGFloat { switch self { case .large: 44; case .medium: 37; case .small: 30 } }
        var icon: CGFloat { switch self { case .large: 26; case .medium: 22; case .small: 18 } }
        var playIcon: CGFloat { switch self { case .large: 36; case .medium: 28; case .small: 24 } }
    }

    private var orderedDownloadedTabs: [TabCategory] {
        [.ebook, .synced, .audio].filter {
            mediaViewModel.isCategoryDownloaded($0.localCategory, for: item)
        }
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
        let downloadedTabs = orderedDownloadedTabs
        return Group {
            if !downloadedTabs.isEmpty {
                let hasSynced = downloadedTabs.contains(.synced)
                let slots: [TabCategory] = hasSynced ? [.ebook, .synced, .audio] : downloadedTabs
                HStack(spacing: 8) {
                    ForEach(slots, id: \.self) { tab in
                        let isPresent = downloadedTabs.contains(tab)
                        let size = buttonSize(for: tab, in: downloadedTabs)
                        if isPresent {
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

    @ViewBuilder
    private func tabButton(for tab: TabCategory, size: ButtonSize) -> some View {
        let isTabHovered = hoveredTab == tab

        Button {
            openMedia(for: tab.localCategory)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: size.frame, height: size.frame)
                if isTabHovered {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: size.playIcon))
                        .foregroundStyle(.white)
                } else {
                    Group {
                        switch tab {
                            case .synced:
                                ReadaloudIcon(size: size.icon)
                            case .ebook:
                                Image("ebookIcon")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: size.icon, height: size.icon)
                            case .audio:
                                Image("audioIcon")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: size.icon, height: size.icon)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: size.frame, height: size.frame)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(tab.localCategory == .ebook ? "Ebook" : tab.localCategory == .audio ? "Audiobook" : "Readaloud")")
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
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
