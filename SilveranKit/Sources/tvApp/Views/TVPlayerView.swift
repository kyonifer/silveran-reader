import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct TVPlayerView: View {
    let book: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var viewModel = TVPlayerViewModel()
    @State private var showControls = true
    @State private var showChapterList = false
    @State private var showSpeedPicker = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var cachedCoverImage: Image?
    @FocusState private var focusedControl: FocusedControl?
    @FocusState private var isBackgroundFocused: Bool
    @State private var lastFocusedControl: FocusedControl = .playPause
    @State private var fontFamily: String = kDefaultFontFamily

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        playerContent
        .ignoresSafeArea()
        .onAppear {
            Task {
                await viewModel.loadBook(book)
                fontFamily = await SettingsActor.shared.config.reading.fontFamily
            }
            resetControlsTimer()
            loadCoverImage()
            focusedControl = .playPause
        }
        .onChange(of: focusedControl) { _, newValue in
            guard showControls else { return }
            if let newValue {
                lastFocusedControl = newValue
                showControlsTemporarily()
            } else {
                DispatchQueue.main.async {
                    if showControls, focusedControl == nil {
                        focusedControl = lastFocusedControl
                    }
                }
            }
        }
        .onChange(of: showControls) { _, visible in
            if visible {
                isBackgroundFocused = false
                if focusedControl == nil {
                    focusedControl = lastFocusedControl
                }
            } else {
                focusedControl = nil
                isBackgroundFocused = true
            }
        }
        .onChange(of: mediaViewModel.coverState(for: book, variant: mediaViewModel.coverVariant(for: book)).image) { _, newImage in
            if let newImage, cachedCoverImage == nil {
                cachedCoverImage = newImage
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onPlayPauseCommand {
            if isScrubbing {
                viewModel.seekToProgress(scrubProgress)
                isScrubbing = false
            } else {
                viewModel.playPause()
            }
            showControlsTemporarily()
        }
        .onExitCommand {
            if isScrubbing {
                isScrubbing = false
                scrubProgress = viewModel.bookProgress
            } else if showChapterList || showSpeedPicker {
                showChapterList = false
                showSpeedPicker = false
            } else {
                dismiss()
            }
        }
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .sheet(isPresented: $showChapterList) {
            TVChapterListView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSpeedPicker) {
            TVSpeedPickerView(viewModel: viewModel)
        }
        .alert(
            "Server Has Newer Position",
            isPresented: $viewModel.showServerPositionDialog
        ) {
            Button("Go to New Position") {
                viewModel.acceptServerPosition()
            }
            Button("Stay Here", role: .cancel) {
                viewModel.declineServerPosition()
            }
        } message: {
            Text(viewModel.serverPositionDescription)
        }
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                subtitleView
                    .padding(.horizontal, 60)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .center
                    )

                statsOverlay
                    .opacity(showControls ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: showControls)

                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black, .black.opacity(0.8), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 350)
                    .allowsHitTesting(false)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 300)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
                .opacity(showControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showControls)

                if !showControls {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .focusable()
                        .focused($isBackgroundFocused)
                        .onMoveCommand { direction in
                            handleMoveCommand(direction)
                        }
                }

                headerOverlay
                controlsOverlay
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var headerOverlay: some View {
        ZStack {
            headerView
                .padding(60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            coverView
                .padding(.trailing, 60)
                .offset(y: -60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .opacity(showControls ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: showControls)
        .allowsHitTesting(false)
    }

    private var controlsOverlay: some View {
        controlsView
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .opacity(showControls ? 1 : 0)
            .disabled(!showControls)
            .animation(.easeInOut(duration: 0.3), value: showControls)
    }

    private var backgroundView: some View {
        ZStack {
            Color.black

            if let image = cachedCoverImage {
                GeometryReader { geometry in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 80)
                        .saturation(0.8)
                        .opacity(0.6)
                        .drawingGroup()
                }
            }
        }
        .ignoresSafeArea()
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.bookTitle)
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text(viewModel.chapterTitle)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var subtitleView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !viewModel.previousLineText.isEmpty {
                Text(viewModel.previousLineText)
                    .font(.title2)
                    .fontDesign(fontDesign)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.currentLineText.isEmpty {
                Text(viewModel.currentLineText)
                    .font(.largeTitle)
                    .fontDesign(fontDesign)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.nextLineText.isEmpty {
                Text(viewModel.nextLineText)
                    .font(.title2)
                    .fontDesign(fontDesign)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: showControls ? 800 : 1200)
        .padding(.horizontal, showControls ? 40 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: showControls)
    }

    private var fontDesign: Font.Design? {
        switch fontFamily {
        case "System Default", "sans-serif":
            return .default
        case "serif":
            return .serif
        case "monospace":
            return .monospaced
        default:
            return nil
        }
    }

    private var statsOverlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.title3)
                    Text(formatTimeMinutesSeconds(viewModel.chapterDuration - viewModel.currentTime))
                        .font(.title3)
                }
                .foregroundStyle(.white.opacity(0.7))

                Spacer()

                HStack(spacing: 8) {
                    Text(formatTimeHoursMinutes(viewModel.bookDuration - viewModel.bookElapsed))
                        .font(.title3)
                    Image(systemName: "book.fill")
                        .font(.title3)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
        .allowsHitTesting(false)
    }

    private var coverView: some View {
        Group {
            if let image = cachedCoverImage {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .frame(width: 300, height: 450)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }

    private var controlsView: some View {
        VStack(spacing: 24) {
            progressBar

            HStack(spacing: 60) {
                Button {
                    showChapterList = true
                    showControlsTemporarily()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 26))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .chapterList)

                Button {
                    viewModel.previousChapter()
                    showControlsTemporarily()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .previousChapter)

                Button {
                    viewModel.skipBackward()
                    showControlsTemporarily()
                } label: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 30))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .skipBackward)

                Button {
                    viewModel.playPause()
                    showControlsTemporarily()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 80))
                }
                .buttonStyle(PlayerControlButtonStyle(isLarge: true))
                .focused($focusedControl, equals: .playPause)

                Button {
                    viewModel.skipForward()
                    showControlsTemporarily()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 30))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .skipForward)

                Button {
                    viewModel.nextChapter()
                    showControlsTemporarily()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .nextChapter)

                Button {
                    showSpeedPicker = true
                    showControlsTemporarily()
                } label: {
                    Text("\(viewModel.playbackRate, specifier: "%.1f")x")
                        .font(.system(size: 26))
                }
                .buttonStyle(PlayerControlButtonStyle())
                .focused($focusedControl, equals: .speed)
            }
        }
        .transition(.opacity)
    }

    private var progressBar: some View {
        let displayProgress = isScrubbing ? scrubProgress : viewModel.chapterProgress

        let progressButton = Button {
            if isScrubbing {
                seekToChapterProgress(scrubProgress)
                isScrubbing = false
            } else {
                isScrubbing = true
                scrubProgress = viewModel.chapterProgress
            }
            showControlsTemporarily()
        } label: {
            VStack(spacing: 8) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: isScrubbing ? 12 : 8)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(isScrubbing ? .blue : .white)
                            .scaleEffect(x: max(0.001, displayProgress), y: 1, anchor: .leading)
                    }
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 0.2), value: isScrubbing)

                HStack {
                    Text(isScrubbing ? formatScrubTime(scrubProgress) : viewModel.currentTimeFormatted)
                    Spacer()
                    if isScrubbing {
                        Text("Scrubbing - Press Select to Seek")
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(viewModel.chapterDurationFormatted)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
        }
        .buttonStyle(ProgressBarButtonStyle())
        .focused($focusedControl, equals: .progressBar)
        if isScrubbing {
            return AnyView(
                progressButton.onMoveCommand { direction in
                    handleMoveCommand(direction)
                }
            )
        }
        return AnyView(progressButton)
    }

    private func formatScrubTime(_ progress: Double) -> String {
        let totalSeconds = progress * viewModel.chapterDuration
        let hours = Int(totalSeconds) / 3600
        let mins = (Int(totalSeconds) % 3600) / 60
        let secs = Int(totalSeconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private func seekToChapterProgress(_ progress: Double) {
        let targetTime = progress * viewModel.chapterDuration
        let currentTime = viewModel.chapterProgress * viewModel.chapterDuration
        let delta = targetTime - currentTime
        if delta > 0 {
            viewModel.skipForward(seconds: delta)
        } else {
            viewModel.skipBackward(seconds: -delta)
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        if isScrubbing {
            resetControlsTimer()
            let stepSeconds = 5.0
            let step = viewModel.chapterDuration > 0 ? stepSeconds / viewModel.chapterDuration : 0.01
            switch direction {
            case .left:
                scrubProgress = max(0, scrubProgress - step)
            case .right:
                scrubProgress = min(1, scrubProgress + step)
            case .up, .down:
                break
            @unknown default:
                break
            }
            return
        }

        if showControls {
            showControlsTemporarily()
            return
        }

        showControlsTemporarily()

        switch direction {
        case .left:
            viewModel.skipBackward(seconds: 10)
        case .right:
            viewModel.skipForward(seconds: 10)
        case .up, .down:
            break
        @unknown default:
            break
        }
    }

    private func showControlsTemporarily() {
        if !showControls {
            showControls = true
        } else if focusedControl == nil {
            focusedControl = lastFocusedControl
        }
        resetControlsTimer()
    }

    private func resetControlsTimer() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if viewModel.isPlaying && !isScrubbing {
                showControls = false
            }
        }
    }

    private func loadCoverImage() {
        let variant = mediaViewModel.coverVariant(for: book)
        mediaViewModel.ensureCoverLoaded(for: book, variant: variant)
        let coverState = mediaViewModel.coverState(for: book, variant: variant)
        if let image = coverState.image {
            cachedCoverImage = image
        }
    }

}

private enum FocusedControl: Hashable {
    case progressBar
    case chapterList
    case previousChapter
    case skipBackward
    case playPause
    case skipForward
    case nextChapter
    case speed
}

private struct PlayerControlButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .padding(isLarge ? 24 : 24)
            .background(
                Circle()
                    .fill(isFocused ? .white : .white.opacity(0.2))
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

private struct ProgressBarButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? .white.opacity(0.15) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? .white : .clear, lineWidth: 4)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
