import SwiftUI

struct DownloadCancelProgressIcon: View {
    let progress: Double?
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat
    let showsCancel: Bool

    var body: some View {
        ZStack {
            if let progress {
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            }

            if showsCancel {
                Circle()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: max(size - 8, 10), height: max(size - 8, 10))
                Image(systemName: "xmark")
                    .font(.system(size: max(size * 0.42, 8), weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

struct MediaItemCardTopTabs: View {
    let item: BookMetadata
    let coverWidth: CGFloat
    let isHoveringCard: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    enum TabCategory: CaseIterable {
        case ebook
        case audio
        case synced

        var localMediaCategory: LocalMediaCategory {
            switch self {
                case .ebook: return .ebook
                case .audio: return .audio
                case .synced: return .synced
            }
        }

        var title: String {
            switch self {
                case .ebook: return "Ebook"
                case .audio: return "Audiobook"
                case .synced: return "Readaloud"
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
                    Image("audioIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                case .synced:
                    ReadaloudIcon(size: size)
            }
        }
    }

    enum TabStatus: Equatable {
        case unavailable
        case availableNotDownloaded
        case downloaded
        case downloading(progress: Double?)

        var color: Color {
            switch self {
                case .unavailable:
                    return .gray.opacity(0.4)
                case .availableNotDownloaded:
                    return .blue
                case .downloaded:
                    return .green
                case .downloading:
                    return .blue
            }
        }

        var isUnavailable: Bool {
            if case .unavailable = self {
                return true
            }
            return false
        }
    }

    private let statusLineHeight: CGFloat = 3

    private func tabStatus(for tab: TabCategory) -> TabStatus {
        let category = tab.localMediaCategory

        if mediaViewModel.isCategoryDownloadInProgress(for: item, category: category) {
            let progress = mediaViewModel.downloadProgressFraction(for: item, category: category)
            return .downloading(progress: progress)
        }

        if mediaViewModel.isCategoryDownloaded(category, for: item) {
            return .downloaded
        }

        switch category {
            case .ebook:
                return item.hasAvailableEbook ? .availableNotDownloaded : .unavailable
            case .audio:
                return item.hasAvailableAudiobook ? .availableNotDownloaded : .unavailable
            case .synced:
                return item.hasAvailableReadaloud ? .availableNotDownloaded : .unavailable
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TabCategory.allCases, id: \.self) { tab in
                let status = tabStatus(for: tab)
                Rectangle()
                    .fill(status.color)
                    .frame(height: statusLineHeight)
            }
        }
        .frame(width: coverWidth)
    }
}

struct MediaItemCardTopTabsButtonOverlay: View {
    let item: BookMetadata
    let coverWidth: CGFloat
    let isSelected: Bool
    let isHoveringCard: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var hoveredTab: MediaItemCardTopTabs.TabCategory?

    var body: some View {
        if isHoveringCard {
            let downloadedTabs = orderedDownloadedTabs
            if !downloadedTabs.isEmpty {
                let hasSynced = downloadedTabs.contains(.synced)
                let slots: [MediaItemCardTopTabs.TabCategory] = hasSynced
                    ? [.ebook, .synced, .audio]
                    : downloadedTabs
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

    private enum ButtonSize {
        case large, medium, small
        var frame: CGFloat { switch self { case .large: 44; case .medium: 37; case .small: 30 } }
        var icon: CGFloat { switch self { case .large: 26; case .medium: 22; case .small: 18 } }
        var playIcon: CGFloat { switch self { case .large: 36; case .medium: 28; case .small: 24 } }
    }

    private var orderedDownloadedTabs: [MediaItemCardTopTabs.TabCategory] {
        [.ebook, .synced, .audio].filter {
            mediaViewModel.isCategoryDownloaded($0.localMediaCategory, for: item)
        }
    }

    private func buttonSize(
        for tab: MediaItemCardTopTabs.TabCategory,
        in tabs: [MediaItemCardTopTabs.TabCategory]
    ) -> ButtonSize {
        let hasSynced = tabs.contains(.synced)
        switch tabs.count {
            case 1: return .large
            case 2: return hasSynced ? (tab == .synced ? .large : .small) : .medium
            default: return tab == .synced ? .large : .small
        }
    }

    @ViewBuilder
    private func tabButton(
        for tab: MediaItemCardTopTabs.TabCategory,
        size: ButtonSize
    ) -> some View {
        let isTabHovered = hoveredTab == tab

        Button {
            openMedia(for: tab.localMediaCategory)
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
                    tab.iconView(size: size.icon)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: size.frame, height: size.frame)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(tab.title)")
        #if os(macOS)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
        #endif
    }

    private func openMedia(for category: LocalMediaCategory) {
        #if os(macOS)
        guard #available(macOS 13.0, *) else { return }
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
        #endif
    }
}
