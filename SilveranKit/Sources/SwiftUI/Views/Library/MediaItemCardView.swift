import SwiftUI

#if os(iOS)
private struct MediaNavigationPathKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: Binding<NavigationPath>? = nil
}

extension EnvironmentValues {
    var mediaNavigationPath: Binding<NavigationPath>? {
        get { self[MediaNavigationPathKey.self] }
        set { self[MediaNavigationPathKey.self] = newValue }
    }
}
#endif

struct MediaItemCardMetrics {
    let tileWidth: CGFloat
    let cardPadding: CGFloat
    let coverCornerRadius: CGFloat
    let contentSpacing: CGFloat
    let coverWidth: CGFloat
    let maxCardHeight: CGFloat
    let coverContainerHeight: CGFloat
    let titleContainerHeight: CGFloat
    let titleToAuthorGap: CGFloat

    static func make(
        for tileWidth: CGFloat,
        mediaKind _: MediaKind,
        coverPreference: CoverPreference = .preferEbook,
    ) -> MediaItemCardMetrics {
        let cardPadding = 2.0
        let coverWidth = max(tileWidth - (cardPadding * 2), tileWidth * 0.90)
        let contentSpacing = max(4, tileWidth * 0.03)

        let tallestCoverAspectRatio: CGFloat = 1.0 / coverPreference.preferredContainerAspectRatio
        let tallestCoverHeight = coverWidth * tallestCoverAspectRatio

        let progressBarHeight: CGFloat = 3
        let progressBarTopPadding: CGFloat = 4

        let estimatedLineHeight: CGFloat = 16
        let maxTitleLines: CGFloat = 2
        let titleContainerHeight = estimatedLineHeight * maxTitleLines

        let authorRowHeight: CGFloat = 20
        let authorRowBottomPadding: CGFloat = 0
        let titleToAuthorGap: CGFloat = 2

        let coverContainerHeight = tallestCoverHeight + progressBarTopPadding + progressBarHeight

        let maxCardHeight =
            (cardPadding * 2) + coverContainerHeight + contentSpacing + titleContainerHeight
            + titleToAuthorGap + authorRowHeight + authorRowBottomPadding

        return MediaItemCardMetrics(
            tileWidth: tileWidth,
            cardPadding: cardPadding,
            coverCornerRadius: max(12, tileWidth * 0.06),
            contentSpacing: contentSpacing,
            coverWidth: coverWidth,
            maxCardHeight: maxCardHeight,
            coverContainerHeight: coverContainerHeight,
            titleContainerHeight: titleContainerHeight,
            titleToAuthorGap: titleToAuthorGap,
        )
    }
}

struct MediaItemCardView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    let metrics: MediaItemCardMetrics
    let isSelected: Bool
    let showAudioIndicator: Bool
    let sourceLabel: String?
    let seriesPositionBadge: String?
    let coverPreference: CoverPreference
    let progressStyle: ProgressIndicatorStyle
    let onSelect: (BookMetadata) -> Void
    let onInfo: (BookMetadata) -> Void
    var onEditMetadata: (([String]) -> Void)? = nil
    var debugContext: String? = nil
    @Environment(MediaViewModel.self) private var mediaViewModel
    #if os(macOS)
    @State private var isHovered = false
    @State private var doubleCoverSwapping = false
    #endif
    #if os(iOS)
    @Environment(\.mediaNavigationPath) private var mediaNavigationPath
    @Environment(\.editMetadataAction) private var editMetadataAction
    @State private var pendingDetailsNavigation = false
    @State private var pendingPlayerCategory: LocalMediaCategory?
    #endif

    var body: some View {
        #if os(iOS)
        if let playerData = preferredPlayerBookData {
            NavigationLink(value: playerData) {
                cardContent
            }
            .buttonStyle(.plain)
            .background(deferredNavigationLinks)
            .contextMenu { iOSCardContextMenu }
        } else {
            NavigationLink(value: item) {
                cardContent
            }
            .buttonStyle(.plain)
            .background(deferredNavigationLinks)
            .contextMenu { iOSCardContextMenu }
        }
        #else
        cardContent
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSCardContextMenu: some View {
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

        Divider()

        iOSContextMenuMediaOption(for: .ebook, label: "Ebook")
        iOSContextMenuMediaOption(for: .audio, label: "Audiobook")
        iOSContextMenuMediaOption(for: .synced, label: "Readaloud")
    }

    @ViewBuilder
    private func iOSContextMenuMediaOption(for category: LocalMediaCategory, label: String)
        -> some View
    {
        let isDownloaded = mediaViewModel.isCategoryDownloaded(category, for: item)
        let isDownloading = mediaViewModel.isCategoryDownloadInProgress(
            for: item,
            category: category,
        )
        let isAvailable: Bool = {
            switch category {
                case .ebook: return item.hasAvailableEbook
                case .audio: return item.hasAvailableAudiobook
                case .synced: return item.hasAvailableReadaloud
            }
        }()

        if isDownloaded && mediaViewModel.hasCachedMedia(category, for: item) {
            Button(role: .destructive) {
                mediaViewModel.deleteDownload(for: item, category: category)
            } label: {
                Label("Local \(label)", systemImage: "trash")
            }
        } else if isDownloading {
            Button(role: .destructive) {
                mediaViewModel.cancelDownload(for: item, category: category)
            } label: {
                Label("Cancel \(label)", systemImage: "xmark.circle")
            }
        } else if isAvailable {
            Button {
                mediaViewModel.startDownload(for: item, category: category)
            } label: {
                Label(label, systemImage: "arrow.down.circle")
            }
        }
    }
    #endif

    #if os(iOS)
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
        return makePlayerBookData(for: category)
    }

    private func makePlayerBookData(for category: LocalMediaCategory) -> PlayerBookData {
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

    private func handleDetailsNavigation() {
        if let mediaNavigationPath {
            mediaNavigationPath.wrappedValue.append(item)
        } else {
            pendingDetailsNavigation = true
        }
    }

    private func handlePlayerNavigation(_ category: LocalMediaCategory) {
        let bookData = makePlayerBookData(for: category)
        if let mediaNavigationPath {
            mediaNavigationPath.wrappedValue.append(bookData)
        } else {
            pendingPlayerCategory = category
        }
    }

    @ViewBuilder
    private var deferredNavigationLinks: some View {
        if mediaNavigationPath == nil {
            ZStack {
                NavigationLink(isActive: $pendingDetailsNavigation) {
                    iOSBookDetailView(item: item, mediaKind: mediaKind)
                } label: {
                    EmptyView()
                }

                NavigationLink(
                    tag: LocalMediaCategory.synced,
                    selection: $pendingPlayerCategory,
                ) {
                    playerDestination(for: .synced)
                } label: {
                    EmptyView()
                }

                NavigationLink(
                    tag: LocalMediaCategory.ebook,
                    selection: $pendingPlayerCategory,
                ) {
                    playerDestination(for: .ebook)
                } label: {
                    EmptyView()
                }

                NavigationLink(
                    tag: LocalMediaCategory.audio,
                    selection: $pendingPlayerCategory,
                ) {
                    playerDestination(for: .audio)
                } label: {
                    EmptyView()
                }
            }
            .frame(width: 0, height: 0)
            .hidden()
        }
    }

    @ViewBuilder
    private func playerDestination(for category: LocalMediaCategory) -> some View {
        let bookData = makePlayerBookData(for: category)
        switch category {
            case .audio:
                AudiobookPlayerView(bookData: bookData)
                    .navigationBarTitleDisplayMode(.inline)
            case .ebook, .synced:
                EbookPlayerView(bookData: bookData)
                    .navigationBarTitleDisplayMode(.inline)
        }
    }
    #endif

    private var isDoubleCover: Bool {
        coverPreference == .storytellerDouble
    }

    private var cardContent: some View {
        let placeholderColor = Color(white: 0.2)
        let coverVariant = resolveCoverVariant(for: item)
        let containerAspectRatio: CGFloat = coverPreference.preferredContainerAspectRatio
        let standardCoverState = mediaViewModel.coverState(for: item, variant: .standard)
        let audioCoverState = mediaViewModel.coverState(for: item, variant: .audioSquare)
        let shouldRenderDoubleCover =
            isDoubleCover && standardCoverState.image != nil && audioCoverState.image != nil

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if shouldRenderDoubleCover {
                        DoubleCoverView(
                            item: item,
                            placeholderColor: placeholderColor,
                            coverWidth: metrics.coverWidth,
                            containerAspectRatio: containerAspectRatio,
                            cornerRadius: metrics.coverCornerRadius,
                            isSwapping: {
                                #if os(macOS)
                                return $doubleCoverSwapping
                                #else
                                return .constant(false)
                                #endif
                            }(),
                            debugContext: debugContext,
                        )
                        .frame(width: metrics.coverWidth)
                        .aspectRatio(containerAspectRatio, contentMode: .fit)
                    } else {
                        MediaItemCoverImage(
                            item: item,
                            placeholderColor: placeholderColor,
                            variant: coverVariant,
                            debugContext: debugContext,
                        )
                        .frame(width: metrics.coverWidth)
                        .aspectRatio(containerAspectRatio, contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: metrics.coverCornerRadius,
                                style: .continuous,
                            )
                        )
                        .stableCoverRendering()
                    }
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .bottomLeading) {
                    if let sourceLabel = sourceLabel {
                        SourceBadge(label: sourceLabel)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showAudioIndicator && !shouldRenderDoubleCover {
                        AudioIndicatorBadge(item: item, coverVariant: coverVariant)
                            .padding(.trailing, 4)
                            .padding(.top, 4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if progressStyle == .circle {
                        let progress = mediaViewModel.progress(for: item.id)
                        if progress > 0 {
                            CircularProgressBadge(progress: progress)
                                .padding(.trailing, 4)
                                .padding(.bottom, 4)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let badge = seriesPositionBadge {
                        Text(badge)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                .black.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous),
                            )
                            .padding(4)
                    }
                }

                #if os(macOS)
                MediaItemCardTopTabsButtonOverlay(
                    item: item,
                    coverWidth: metrics.coverWidth,
                    isSelected: isSelected,
                    isHoveringCard: isHovered,
                )
                .environment(mediaViewModel)
                #endif
            }
            .frame(height: metrics.coverContainerHeight - 7)
            .overlay(
                RoundedRectangle(cornerRadius: metrics.coverCornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            if progressStyle == .line {
                MediaProgressBar(progress: mediaViewModel.progress(for: item.id))
                    .frame(width: metrics.coverWidth)
                    .frame(height: 3)
            }

            Spacer(minLength: metrics.contentSpacing)
                .frame(height: metrics.contentSpacing)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
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
                trailing: metrics.cardPadding,
            )
        )
        .frame(width: metrics.tileWidth, height: metrics.maxCardHeight, alignment: .top)
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture {
            onSelect(item)
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onInfo(item)
                }
        )
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
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
        .zIndex(doubleCoverSwapping ? 1000 : 0)
        #endif
    }

    private var authorRow: some View {
        HStack(spacing: 2) {
            Text(item.authors?.first?.name ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }

    private func resolveCoverVariant(for item: BookMetadata) -> MediaViewModel.CoverVariant {
        mediaViewModel.coverVariant(for: item, preference: coverPreference)
    }
}

struct CircularProgressBadge: View {
    let progress: Double

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(.tint.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}

private struct MediaProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tint.opacity(0.1))
                Capsule()
                    .fill(.tint)
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
    let debugContext: String?

    var body: some View {
        let coverState = mediaViewModel.coverState(for: item, variant: variant)
        let fallbackVariant: MediaViewModel.CoverVariant =
            variant == .standard ? .audioSquare : .standard
        let fallbackState = mediaViewModel.coverState(for: item, variant: fallbackVariant)
        let displayImage = coverState.image ?? fallbackState.image

        ZStack {
            if displayImage == nil {
                placeholderColor
            }
            if let image = displayImage {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: displayImage != nil)
        .task(id: taskIdentifier) {
            debugCoverLog(
                "task imageLoaded=\(coverState.image != nil) fallbackLoaded=\(fallbackState.image != nil)"
            )
            mediaViewModel.ensureCoverLoaded(
                for: item,
                variant: variant,
                debugSource: debugContext,
            )
            mediaViewModel.ensureCoverLoaded(
                for: item,
                variant: fallbackVariant,
                debugSource: debugContext,
            )
        }
        .onAppear {
            debugCoverLog(
                "appear imageLoaded=\(coverState.image != nil) fallbackLoaded=\(fallbackState.image != nil)"
            )
        }
        .onChange(of: coverState.image != nil) { _, loaded in
            debugCoverLog("imageLoaded changed=\(loaded)")
        }
        .onChange(of: fallbackState.image != nil) { _, loaded in
            debugCoverLog("fallbackLoaded changed=\(loaded)")
        }
        .onDisappear {
            debugCoverLog(
                "disappear imageLoaded=\(coverState.image != nil) fallbackLoaded=\(fallbackState.image != nil)"
            )
            mediaViewModel.cancelCoverLoad(for: item, variant: variant)
            mediaViewModel.cancelCoverLoad(for: item, variant: fallbackVariant)
        }
    }

    private func debugCoverLog(_ message: String) {
        guard let debugContext else { return }
        debugLog(
            "[CoverPerf][\(debugContext)] view \(message) title='\(item.title)' id=\(item.id) variant=\(variant)"
        )
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

struct DoubleCoverView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let item: BookMetadata
    let placeholderColor: Color
    let coverWidth: CGFloat
    let containerAspectRatio: CGFloat
    let cornerRadius: CGFloat
    @Binding var isSwapping: Bool
    var debugContext: String? = nil

    #if os(macOS)
    @State private var isHovered = false
    @State private var swapPhase: SwapPhase = .idle
    @State private var audioHoverTask: Task<Void, Never>?

    enum SwapPhase {
        case idle
        case slidingOut
        case swapped
    }
    #endif

    var body: some View {
        let containerHeight = coverWidth / containerAspectRatio
        let scale: CGFloat = {
            #if os(macOS)
            return isHovered ? 0.70 : 0.80
            #else
            return 0.80
            #endif
        }()
        let scaledWidth = coverWidth * scale
        let ebookHeight = scaledWidth / 0.67
        let audioSize = scaledWidth
        let xSpread: CGFloat = {
            #if os(macOS)
            return isHovered ? 0.15 : 0.10
            #else
            return 0.10
            #endif
        }()
        let xShift = coverWidth * xSpread

        let ebookState = mediaViewModel.coverState(for: item, variant: .standard)
        let audioState = mediaViewModel.coverState(for: item, variant: .audioSquare)

        #if os(macOS)
        let audioXOffset: CGFloat =
            switch swapPhase {
                case .idle: xShift
                case .slidingOut: coverWidth * 0.35
                case .swapped: xShift
            }
        let audioScale: CGFloat =
            switch swapPhase {
                case .idle: 1.0
                case .slidingOut: 1.1
                case .swapped: 1.1
            }
        let audioZ: Double =
            switch swapPhase {
                case .idle: 10
                case .slidingOut: 30
                case .swapped: 30
            }
        let ebookXOffset: CGFloat =
            switch swapPhase {
                case .idle: -xShift
                case .slidingOut: -coverWidth * 0.25
                case .swapped: -xShift
            }
        let ebookZ: Double =
            switch swapPhase {
                case .idle: 20
                case .slidingOut: 5
                case .swapped: 5
            }
        #else
        let audioXOffset = xShift
        let audioScale: CGFloat = 1.0
        let audioZ: Double = 10
        let ebookXOffset = -xShift
        let ebookZ: Double = 20
        #endif

        ZStack {
            if ebookState.image != nil && audioState.image != nil {
                coverImage(state: audioState)
                    .frame(width: audioSize, height: audioSize)
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius * 0.8, style: .continuous)
                    )
                    .stableCoverRendering()
                    .scaleEffect(audioScale)
                    .offset(x: audioXOffset)
                    .zIndex(audioZ)
                    #if os(macOS)
                .onHover { hovering in
                    audioHoverTask?.cancel()
                    if hovering {
                        audioHoverTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                swapPhase = .slidingOut
                                isSwapping = true
                            }
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                swapPhase = .swapped
                            }
                        }
                    }
                }
                    #endif

                coverImage(state: ebookState)
                    .frame(width: scaledWidth, height: ebookHeight)
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius * 0.8, style: .continuous)
                    )
                    .stableCoverRendering()
                    .offset(x: ebookXOffset)
                    .zIndex(ebookZ)
            }
        }
        .frame(width: coverWidth, height: containerHeight)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.25)) {
                isHovered = hovering
            }
            if !hovering {
                audioHoverTask?.cancel()
                withAnimation(.easeInOut(duration: 0.3)) {
                    swapPhase = .idle
                    isSwapping = false
                }
            }
        }
        #endif
        .task {
            debugCoverLog(
                "task ebookLoaded=\(ebookState.image != nil) audioLoaded=\(audioState.image != nil)"
            )
            mediaViewModel.ensureCoverLoaded(
                for: item,
                variant: .standard,
                debugSource: debugContext,
            )
            mediaViewModel.ensureCoverLoaded(
                for: item,
                variant: .audioSquare,
                debugSource: debugContext,
            )
        }
        .onAppear {
            debugCoverLog(
                "appear ebookLoaded=\(ebookState.image != nil) audioLoaded=\(audioState.image != nil)"
            )
        }
        .onChange(of: ebookState.image != nil) { _, loaded in
            debugCoverLog("ebookLoaded changed=\(loaded)")
        }
        .onChange(of: audioState.image != nil) { _, loaded in
            debugCoverLog("audioLoaded changed=\(loaded)")
        }
        .onDisappear {
            debugCoverLog(
                "disappear ebookLoaded=\(ebookState.image != nil) audioLoaded=\(audioState.image != nil)"
            )
            mediaViewModel.cancelCoverLoad(for: item, variant: .standard)
            mediaViewModel.cancelCoverLoad(for: item, variant: .audioSquare)
        }
    }

    private func debugCoverLog(_ message: String) {
        let context = debugContext ?? "library"
        debugLog(
            "[MetadataCoverRefresh] doubleCover[\(context)] \(message) title='\(item.title)' id=\(item.id)"
        )
    }

    @ViewBuilder
    private func coverImage(state: MediaViewModel.CoverImageState) -> some View {
        if let image = state.image {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            placeholderColor
        }
    }
}

struct SourceBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
    }
}

struct ReadaloudIcon: View {
    let size: CGFloat

    var body: some View {
        Image("readalong")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size)
    }
}

struct AudioIndicatorBadge: View {
    let item: BookMetadata
    let coverVariant: MediaViewModel.CoverVariant

    private enum BadgeKind {
        case readaloud
        case headphones
        case book
    }

    private var badge: BadgeKind? {
        switch coverVariant {
            case .standard:
                if item.hasAvailableReadaloud { return .readaloud }
                if item.hasAvailableAudiobook { return .headphones }
            case .audioSquare:
                if item.hasAvailableReadaloud { return .readaloud }
                if item.hasAvailableEbook { return .book }
        }
        return nil
    }

    private var helpText: String {
        switch badge {
            case .readaloud: "Readaloud available"
            case .headphones: "Audiobook available"
            case .book: "Ebook available"
            case nil: ""
        }
    }

    var body: some View {
        if let badge {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.7))
                switch badge {
                    case .readaloud:
                        Image("readalong")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                            .foregroundStyle(.gray)
                    case .headphones:
                        Image(systemName: "headphones")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.gray)
                    case .book:
                        Image(systemName: "book.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.gray)
                }
            }
            .frame(width: 18, height: 18)
            #if os(macOS)
            .help(helpText)
            #endif
        }
    }
}
