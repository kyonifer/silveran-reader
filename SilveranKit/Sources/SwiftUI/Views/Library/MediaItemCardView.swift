import SwiftUI

struct MediaItemCardMetrics {
    let tileWidth: CGFloat
    let cardPadding: CGFloat
    let cardCornerRadius: CGFloat
    let coverCornerRadius: CGFloat
    let contentSpacing: CGFloat
    let labelSpacing: CGFloat
    let coverWidth: CGFloat
    let labelLeadingPadding: CGFloat
    let infoIconSize: CGFloat
    let shadowRadius: CGFloat
    let maxCardHeight: CGFloat
    let coverContainerHeight: CGFloat
    let titleContainerHeight: CGFloat
    let titleToAuthorGap: CGFloat

    static func make(
        for tileWidth: CGFloat,
        mediaKind: MediaKind,
    ) -> MediaItemCardMetrics {
        let cardPadding = 4.0
        let coverWidth = max(tileWidth - (cardPadding * 2), tileWidth * 0.90)
        let labelLeadingPadding = max(cardPadding + 6, 12)
        let infoIconSize = max(18, tileWidth * 0.12)
        let contentSpacing = max(8, tileWidth * 0.06)

        let tallestCoverAspectRatio: CGFloat = 1.5
        let tallestCoverHeight = coverWidth * tallestCoverAspectRatio

        let progressBarHeight: CGFloat = 3
        let progressBarTopPadding: CGFloat = 4

        let estimatedLineHeight: CGFloat = 16
        let maxTitleLines: CGFloat = 2
        let titleContainerHeight = estimatedLineHeight * maxTitleLines

        let authorRowHeight: CGFloat = 20
        let authorRowBottomPadding: CGFloat = 4
        let titleToAuthorGap: CGFloat = 2

        let coverContainerHeight = tallestCoverHeight + progressBarTopPadding + progressBarHeight

        let maxCardHeight =
            (cardPadding * 2) + coverContainerHeight + contentSpacing + titleContainerHeight
            + titleToAuthorGap + authorRowHeight + authorRowBottomPadding

        return MediaItemCardMetrics(
            tileWidth: tileWidth,
            cardPadding: cardPadding,
            cardCornerRadius: max(12, tileWidth * 0.08),
            coverCornerRadius: max(12, tileWidth * 0.06),
            contentSpacing: contentSpacing,
            labelSpacing: max(4, tileWidth * 0.03),
            coverWidth: coverWidth,
            labelLeadingPadding: labelLeadingPadding,
            infoIconSize: infoIconSize,
            shadowRadius: max(3, tileWidth * 0.02),
            maxCardHeight: maxCardHeight,
            coverContainerHeight: coverContainerHeight,
            titleContainerHeight: titleContainerHeight,
            titleToAuthorGap: titleToAuthorGap
        )
    }
}

struct MediaItemCardView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    let metrics: MediaItemCardMetrics
    let isSelected: Bool
    let showTopTabs: Bool
    let sourceLabel: String?
    let onSelect: (BookMetadata) -> Void
    let onInfo: (BookMetadata) -> Void
    @Environment(MediaViewModel.self) private var mediaViewModel
    #if os(macOS)
    let isInfoHovered: Bool
    let onInfoHoverChanged: (Bool) -> Void
    @State private var isHoveringCard: Bool = false
    #endif

    var body: some View {
        #if os(iOS)
        NavigationLink(value: item) {
            cardContent
        }
        .buttonStyle(.plain)
        #else
        cardContent
        #endif
    }

    private var cardContent: some View {
        let placeholderColor = Color(red: 56 / 255, green: 18 / 255, blue: 108 / 255)
        let coverVariant = mediaViewModel.coverVariant(for: item)
        let containerAspectRatio: CGFloat = coverVariant.preferredAspectRatio

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottomTrailing) {
                        MediaItemCoverImage(
                            item: item,
                            placeholderColor: placeholderColor,
                            variant: coverVariant
                        )
                        .frame(width: metrics.coverWidth)
                        .aspectRatio(containerAspectRatio, contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: metrics.coverCornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay(alignment: .topLeading) {
                            if mediaViewModel.booksWithUnsyncedProgress.contains(item.id) {
                                UnsyncedProgressBadge()
                                    .padding(8)
                            }
                        }

                        if let sourceLabel = sourceLabel {
                            SourceBadge(label: sourceLabel)
                                .padding(8)
                        }
                    }
                    Spacer(minLength: 0)
                }

                #if os(macOS)
                MediaItemCardTopTabsButtonOverlay(
                    item: item,
                    coverWidth: metrics.coverWidth,
                    isSelected: isSelected,
                    alwaysShow: showTopTabs
                )
                .environment(mediaViewModel)
                #endif
            }
            .frame(height: metrics.coverContainerHeight - 7)
            .clipped()

            MediaProgressBar(progress: item.progress)
                .frame(width: metrics.coverWidth)
                .frame(height: 3)
                .task(id: item.id) {
                    if item.id == "14749693-3d16-4076-b3b3-c8593040fa74" {
                        debugLog("[MediaItemCardView] Book \(item.title) (\(item.id))")
                        debugLog("[MediaItemCardView]   progress: \(item.progress)")
                        debugLog(
                            "[MediaItemCardView]   position: \(item.position != nil ? "exists" : "nil")"
                        )
                        if let position = item.position {
                            debugLog(
                                "[MediaItemCardView]   locator: \(position.locator != nil ? "exists" : "nil")"
                            )
                            if let locator = position.locator {
                                debugLog("[MediaItemCardView]     href: \(locator.href)")
                                debugLog(
                                    "[MediaItemCardView]     locations: \(locator.locations != nil ? "exists" : "nil")"
                                )
                                if let locations = locator.locations {
                                    debugLog(
                                        "[MediaItemCardView]       totalProgression: \(locations.totalProgression ?? -1)"
                                    )
                                    debugLog(
                                        "[MediaItemCardView]       progression: \(locations.progression ?? -1)"
                                    )
                                    debugLog(
                                        "[MediaItemCardView]       position: \(locations.position ?? -1)"
                                    )
                                }
                            }
                            debugLog(
                                "[MediaItemCardView]   updatedAt: \(position.updatedAt ?? "nil")"
                            )
                        }
                    }
                }

            Spacer(minLength: metrics.contentSpacing)
                .frame(height: metrics.contentSpacing)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .frame(height: metrics.titleContainerHeight, alignment: .top)

                authorRow
                    .padding(.top, metrics.titleToAuthorGap)
            }
        }
        .padding(
            EdgeInsets(
                top: metrics.cardPadding,
                leading: metrics.cardPadding,
                bottom: metrics.cardPadding,
                trailing: metrics.cardPadding
            )
        )
        .frame(width: metrics.tileWidth, height: metrics.maxCardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                #if os(macOS)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                #else
            .fill(Color.secondary.opacity(0.08))
                #endif
        )
        .contentShape(Rectangle())
        #if os(macOS)
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    onSelect(item)
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onInfo(item)
                }
        )
        .onHover { hovering in
            isHoveringCard = hovering
        }
        .contextMenu {
            cardContextMenu
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var cardContextMenu: some View {
        let ebookDownloaded = mediaViewModel.isCategoryDownloaded(.ebook, for: item)
        let audioDownloaded = mediaViewModel.isCategoryDownloaded(.audio, for: item)
        let syncedDownloaded = mediaViewModel.isCategoryDownloaded(.synced, for: item)

        if ebookDownloaded || audioDownloaded || syncedDownloaded {
            if ebookDownloaded {
                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: item, category: .ebook)
                } label: {
                    Label("Delete Ebook", systemImage: "trash")
                }
            }

            if audioDownloaded {
                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: item, category: .audio)
                } label: {
                    Label("Delete Audiobook", systemImage: "trash")
                }
            }

            if syncedDownloaded {
                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: item, category: .synced)
                } label: {
                    Label("Delete Readaloud", systemImage: "trash")
                }
            }
        }
    }
    #endif

    private var authorRow: some View {
        HStack(spacing: 2) {
            Text(item.authors?.first?.name ?? "")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            #if os(macOS)
            infoButton
            #endif
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }

    private var infoButton: some View {
        Button {
            onSelect(item)
            onInfo(item)
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: metrics.infoIconSize))
                #if os(macOS)
            .foregroundStyle(
                isInfoHovered ? Color.accentColor : Color.primary.opacity(0.8)
            )
                #else
            .foregroundStyle(Color.primary.opacity(0.8))
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            onInfoHoverChanged(hovering)
        }
        #endif
    }
}

private struct MediaProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.1))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * CGFloat(clamped))
            }
        }
    }
}

private struct MediaItemCoverImage: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let item: BookMetadata
    let placeholderColor: Color
    let variant: MediaViewModel.CoverVariant

    var body: some View {
        let image = mediaViewModel.coverImage(for: item, variant: variant)
        ZStack {
            placeholderColor
            if let image {
                image
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: image != nil)
        .task(id: taskIdentifier) {
            mediaViewModel.ensureCoverLoaded(for: item, variant: variant)
        }
    }

    private var taskIdentifier: String {
        "\(item.id)-\(variantIdentifier)"
    }

    private var variantIdentifier: String {
        switch variant {
            case .standard:
                return "standard"
            case .audioSquare:
                return "audio"
        }
    }
}

private struct SourceBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.black.opacity(0.7)))
    }
}

private struct UnsyncedProgressBadge: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(.white)
            .background(Circle().fill(Color.orange.opacity(0.9)).frame(width: 24, height: 24))
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}
