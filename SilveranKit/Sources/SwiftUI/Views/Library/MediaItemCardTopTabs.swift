import SwiftUI

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

        var iconName: String {
            switch self {
                case .ebook: return "book.fill"
                case .audio: return "headphones"
                case .synced: return "text.bubble"
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
        var icon: some View {
            switch self {
                case .ebook:
                    Image(systemName: "book.fill")
                case .audio:
                    Image(systemName: "headphones")
                case .synced:
                    ReadaloudIcon(size: 26)
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
    let alwaysShow: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var hoveredTab: MediaItemCardTopTabs.TabCategory?
    @State private var showConnectionAlert = false

    private let buttonHeight: CGFloat = 40

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
            return "Unable to download: \(message). Please check your server credentials in Settings."
        }
        return "Cannot download media while disconnected from the server. Please check your connection and try again."
    }

    var body: some View {
        Group {
            if alwaysShow || isSelected {
                HStack(spacing: 0) {
                    ForEach(MediaItemCardTopTabs.TabCategory.allCases, id: \.self) { tab in
                        tabButton(for: tab)
                    }
                }
                .frame(width: coverWidth, height: buttonHeight)
                .background(Color.black.opacity(0.7))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .alert(connectionAlertTitle, isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionAlertMessage)
        }
    }

    @ViewBuilder
    private func tabButton(for tab: MediaItemCardTopTabs.TabCategory) -> some View {
        let status = tabStatus(for: tab)
        let isHovered = hoveredTab == tab
        let statusColor = status.color

        Button {
            handleTabTap(for: tab)
        } label: {
            ZStack {
                Group {
                    if case .downloading(let progress) = status {
                        if isHovered {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                        } else if let progress = progress {
                            ZStack {
                                Circle()
                                    .stroke(statusColor.opacity(0.3), lineWidth: 2.5)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(statusColor, lineWidth: 2.5)
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 24, height: 24)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .tint(statusColor)
                        }
                    } else if isHovered && status == .availableNotDownloaded {
                        if hasConnectionError {
                            ZStack {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 24, height: 24)
                                Image(systemName: "exclamationmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                        }
                    } else if isHovered && status == .downloaded {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                    } else {
                        tab.icon
                            .font(.system(size: 20))
                    }
                }
                .foregroundStyle(statusColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status.isUnavailable)
        .accessibilityLabel("\(tab.title): \(accessibilityLabel(for: status))")
        #if os(macOS)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
        .contextMenu {
            if status == .downloaded {
                Button(role: .destructive) {
                    deleteMedia(for: tab)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        #endif
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
        let variant: MediaViewModel.CoverVariant = item.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: item, variant: variant)
        let bookData = PlayerBookData(
            metadata: item,
            localMediaPath: path,
            category: category,
            coverArt: cover
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
