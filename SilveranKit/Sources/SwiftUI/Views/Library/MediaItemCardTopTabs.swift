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
                    Image(systemName: "headphones")
                        .font(.system(size: size))
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
    @State private var showConnectionAlert = false
    private let availableMediaColor = Color.gray.opacity(0.72)

    private enum ButtonSize {
        case large, medium, small
        var frame: CGFloat { switch self { case .large: 44; case .medium: 37; case .small: 30 } }
        var icon: CGFloat { switch self { case .large: 26; case .medium: 22; case .small: 18 } }
        var playIcon: CGFloat { switch self { case .large: 36; case .medium: 28; case .small: 24 } }
    }

    private var availableTabs: [MediaItemCardTopTabs.TabCategory] {
        [.ebook, .synced, .audio].filter { tabStatus(for: $0) != .unavailable }
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

    private var hasConnectionError: Bool {
        if mediaViewModel.lastNetworkOpSucceeded == false { return true }
        if case .error = mediaViewModel.connectionStatus { return true }
        return false
    }

    private var connectionAlertTitle: String {
        if case .error = mediaViewModel.connectionStatus {
            return "Connection Error"
        }
        return "Server Not Connected"
    }

    private var connectionAlertMessage: String {
        if case .error(let message) = mediaViewModel.connectionStatus {
            return
                "Unable to download: \(message). Please check your server credentials in Settings."
        }
        return
            "Cannot download media while disconnected from the server. Please check your connection and try again."
    }

    var body: some View {
        Group {
            if isHoveringCard {
                let tabs = availableTabs
                if !tabs.isEmpty {
                    let slots: [MediaItemCardTopTabs.TabCategory] =
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
        .alert(connectionAlertTitle, isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionAlertMessage)
        }
    }

    @ViewBuilder
    private func tabButton(
        for tab: MediaItemCardTopTabs.TabCategory,
        size: ButtonSize
    ) -> some View {
        let status = tabStatus(for: tab)
        let isHovered = hoveredTab == tab

        Button {
            handleTabTap(for: tab)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: size.frame, height: size.frame)
                tabIcon(for: tab, status: status, isHovered: isHovered, size: size)
            }
            .frame(width: size.frame, height: size.frame)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.title): \(accessibilityLabel(for: status))")
        #if os(macOS)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
        .contextMenu {
            if status == .downloaded
                && mediaViewModel.hasCachedMedia(tab.localMediaCategory, for: item)
            {
                Button(role: .destructive) {
                    deleteMedia(for: tab)
                } label: {
                    Label("Delete Local \(tab.title)", systemImage: "trash")
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func tabIcon(
        for tab: MediaItemCardTopTabs.TabCategory,
        status: MediaItemCardTopTabs.TabStatus,
        isHovered: Bool,
        size: ButtonSize
    ) -> some View {
        if case .downloading(let progress) = status {
            DownloadCancelProgressIcon(
                progress: progress,
                color: .white,
                size: size.icon,
                lineWidth: 2.5,
                showsCancel: isHovered,
            )
        } else if isHovered && status == .availableNotDownloaded {
            if hasConnectionError {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: size.icon, height: size.icon)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: size.icon * 0.6, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size.playIcon))
                    .foregroundStyle(.white)
            }
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

    private func tabStatus(
        for tab: MediaItemCardTopTabs.TabCategory
    ) -> MediaItemCardTopTabs.TabStatus {
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

    private func handleTabTap(for tab: MediaItemCardTopTabs.TabCategory) {
        let category = tab.localMediaCategory
        let status = tabStatus(for: tab)

        switch status {
            case .availableNotDownloaded:
                if hasConnectionError {
                    showConnectionAlert = true
                } else {
                    mediaViewModel.startDownload(for: item, category: category)
                }
            case .downloaded:
                openMedia(for: category)
            case .downloading:
                mediaViewModel.cancelDownload(for: item, category: category)
            case .unavailable:
                break
        }
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

    private func deleteMedia(for tab: MediaItemCardTopTabs.TabCategory) {
        let category = tab.localMediaCategory
        mediaViewModel.deleteDownload(for: item, category: category)
    }

    private func accessibilityLabel(
        for status: MediaItemCardTopTabs.TabStatus
    ) -> String {
        switch status {
            case .unavailable:
                return "Not available"
            case .availableNotDownloaded:
                return "Available for download"
            case .downloaded:
                return "Downloaded"
            case .downloading:
                return "Downloading"
        }
    }
}
