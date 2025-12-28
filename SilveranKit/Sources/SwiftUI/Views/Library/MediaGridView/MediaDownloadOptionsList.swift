import SwiftUI

struct MediaDownloadOptionsList: View {
    let item: BookMetadata
    private let options: [MediaDownloadOption]
    private let onAction: (() -> Void)?

    init(
        item: BookMetadata,
        options: [MediaDownloadOption]? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.item = item
        self.options = options ?? MediaGridViewUtilities.mediaDownloadOptions(for: item)
        self.onAction = onAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                MediaDownloadOptionRow(item: item, option: option, onAction: onAction)
            }
        }
    }
}

struct MediaDownloadOptionRow: View {
    let item: BookMetadata
    let option: MediaDownloadOption
    let onAction: (() -> Void)?
    @Environment(MediaViewModel.self) private var mediaViewModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var showConnectionAlert = false
    @State private var isHovered = false

    private var hasConnectionError: Bool {
        if mediaViewModel.lastNetworkOpSucceeded == false { return true }
        if case .error = mediaViewModel.connectionStatus { return true }
        return false
    }

    private var isAuthError: Bool {
        if case .error = mediaViewModel.connectionStatus { return true }
        return false
    }

    private var connectionAlertTitle: String {
        isAuthError ? "Connection Error" : "Server Not Connected"
    }

    private var connectionAlertMessage: String {
        if case .error(let message) = mediaViewModel.connectionStatus {
            return "Unable to download: \(message). Please check your server credentials in Settings."
        }
        return "Cannot download media while disconnected from the server. Please check your connection and try again."
    }

    var body: some View {
        #if os(iOS)
        VStack(spacing: 0) {
            if mediaViewModel.isCategoryDownloaded(option.category, for: item) {
                downloadedControls
            } else {
                downloadControls
            }
        }
        .alert(connectionAlertTitle, isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionAlertMessage)
        }
        #else
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    switch option.iconType {
                        case .system(let name):
                            Image(systemName: name)
                                .font(.system(size: 16))
                        case .custom(let name):
                            Image(name)
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                        case .readaloud:
                            Image(systemName: "waveform")
                    }
                }
                .frame(width: 20, height: 20)
                Text(option.title)
            }
            .font(.body)

            Spacer()

            if mediaViewModel.isCategoryDownloaded(option.category, for: item) {
                downloadedControls
            } else {
                downloadControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            isHovered = hovering
        }
        .alert(connectionAlertTitle, isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionAlertMessage)
        }
        #endif
    }

    private var isDownloadInProgress: Bool {
        mediaViewModel.isCategoryDownloadInProgress(for: item, category: option.category)
    }

    private func cancelDownload() {
        mediaViewModel.cancelDownload(for: item, category: option.category)
        onAction?()
    }

    @ViewBuilder
    private var downloadedControls: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            NavigationLink(value: makePlayerBookData()) {
                HStack(spacing: 10) {
                    Group {
                        switch option.iconType {
                            case .system(let name):
                                Image(systemName: name)
                            case .custom(let name):
                                Image(name)
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                            case .readaloud:
                                Image(systemName: "waveform")
                        }
                    }
                    .font(.system(size: 16))
                    Text(option.openTitle)
                        .font(.body)
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.green)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.openTitle)

            Button {
                mediaViewModel.deleteDownload(for: item, category: option.category)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red)
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.deleteTitle)
        }
        #else
        HStack(spacing: 12) {
            Button {
                openMedia()
            } label: {
                Image(systemName: "play.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.openTitle)

            Button {
                mediaViewModel.openMediaFolder(for: item, category: option.category)
            } label: {
                Image(systemName: "folder")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(option.title) in Finder")

            Button {
                mediaViewModel.deleteDownload(for: item, category: option.category)
            } label: {
                Image(systemName: "trash")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.deleteTitle)
        }
        #endif
    }

    @ViewBuilder
    private var downloadControls: some View {
        #if os(iOS)
        HStack(spacing: 8) {
            if !isDownloadInProgress {
                Button {
                    if hasConnectionError {
                        showConnectionAlert = true
                    } else {
                        mediaViewModel.startDownload(for: item, category: option.category)
                        onAction?()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            switch option.iconType {
                                case .system(let name):
                                    Image(systemName: name)
                                case .custom(let name):
                                    Image(name)
                                        .renderingMode(.template)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 18, height: 18)
                                case .readaloud:
                                    Image(systemName: "waveform")
                            }
                        }
                        .font(.system(size: 16))
                        Text(option.downloadTitle)
                            .font(.body)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.downloadTitle)
            } else {
                HStack(spacing: 10) {
                    if let fraction = mediaViewModel.downloadProgressFraction(
                        for: item,
                        category: option.category
                    ) {
                        ProgressView(value: fraction, total: 1)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(maxWidth: 60)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.8)
                    }
                    Text("Downloading...")
                        .font(.body)
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.7))
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 8))

                Button {
                    cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red)
                        .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel \(option.downloadTitle)")
            }
        }
        #else
        HStack(spacing: 10) {
            if !isDownloadInProgress {
                Button {
                    if hasConnectionError {
                        showConnectionAlert = true
                    } else {
                        mediaViewModel.startDownload(for: item, category: option.category)
                        onAction?()
                    }
                } label: {
                    if isHovered && hasConnectionError {
                        ZStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 20, height: 20)
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .imageScale(.large)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.downloadTitle)
            }

            if let fraction = mediaViewModel.downloadProgressFraction(
                for: item,
                category: option.category
            ) {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(ThinCircularProgressViewStyle())
            } else if isDownloadInProgress {
                ProgressView()
                    .progressViewStyle(ThinCircularProgressViewStyle())
            }

            if isDownloadInProgress {
                Button {
                    cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel \(option.downloadTitle)")
            }
        }
        #endif
    }

    private func makePlayerBookData() -> PlayerBookData {
        let freshMetadata = mediaViewModel.library.bookMetaData.first { $0.id == item.id } ?? item
        let path = mediaViewModel.localMediaPath(for: item.id, category: option.category)
        let variant: MediaViewModel.CoverVariant = freshMetadata.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: freshMetadata, variant: variant)
        return PlayerBookData(
            metadata: freshMetadata,
            localMediaPath: path,
            category: option.category,
            coverArt: cover
        )
    }

    private func openMedia() {
        #if os(macOS)
        guard #available(macOS 13.0, *) else { return }
        let windowID: String
        switch option.category {
            case .audio:
                windowID = "AudiobookPlayer"
            case .ebook, .synced:
                windowID = "EbookPlayer"
        }
        openWindow(id: windowID, value: makePlayerBookData())
        #endif
        onAction?()
    }
}

struct ThinCircularProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThinCircularProgressBody(configuration: configuration)
    }

    private struct ThinCircularProgressBody: View {
        let configuration: Configuration
        @State private var rotation: Double = 0
        @State private var animating = false

        private let lineWidth: CGFloat = 1.3

        var body: some View {
            Group {
                if let fraction = configuration.fractionCompleted {
                    Circle()
                        .trim(from: 0, to: max(0.02, CGFloat(fraction)))
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .trim(from: 0, to: 0.55)
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(rotation))
                        .onAppear { startAnimating() }
                        .onDisappear { stopAnimating() }
                }
            }
            .frame(width: 12, height: 12)
            .foregroundStyle(.secondary)
        }

        private func startAnimating() {
            guard !animating else { return }
            animating = true
            withAnimation(Animation.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }

        private func stopAnimating() {
            animating = false
            rotation = 0
        }
    }
}
