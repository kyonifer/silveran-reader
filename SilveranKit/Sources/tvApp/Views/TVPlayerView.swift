import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI
import UIKit

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
    @State private var isScrubSettling = false
    @State private var scrubTargetProgress: Double = 0
    @State private var scrubSettleTask: Task<Void, Never>?
    @State private var cachedCoverImage: Image?
    @FocusState private var focusedControl: FocusedControl?
    @FocusState private var isBackgroundFocused: Bool
    @State private var lastFocusedControl: FocusedControl = .progressBar
    @State private var fontFamily: String = kDefaultFontFamily
    @State private var forceInstantScroll = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        playerContent
        .ignoresSafeArea()
        .onAppear {
            viewModel.usesFullChapterCache = true
            Task {
                await viewModel.loadBook(book)
                fontFamily = await SettingsActor.shared.config.reading.fontFamily
            }
            resetControlsTimer()
            loadCoverImage()
            focusedControl = .progressBar
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
                focusedControl = .progressBar
                lastFocusedControl = .progressBar
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
        .onChange(of: viewModel.chapterProgress) { _, newValue in
            clearScrubSettlingIfNeeded(for: newValue)
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onPlayPauseCommand {
            viewModel.playPause()
            showControlsTemporarily()
        }
        .onExitCommand {
            if showChapterList || showSpeedPicker {
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
                            handleBackgroundMove(direction)
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(viewModel.allChapterLines) { line in
                        Text(line.text)
                            .font(.title)
                            .fontDesign(fontDesign)
                            .foregroundStyle(.white.opacity(line.index == viewModel.currentEntryIndex ? 1 : 0.35))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.index)
                    }
                }
                .padding(.vertical, 300)
            }
            .scrollDisabled(true)
            .onChange(of: viewModel.currentEntryIndex) { _, _ in
                scrollToCurrent(proxy, animated: !showControls)
            }
            .onChange(of: viewModel.allChapterLines.count) { _, _ in
                forceInstantScroll = true
                DispatchQueue.main.async {
                    scrollToCurrent(proxy, animated: false, consumeForce: false)
                }
            }
        }
        .frame(maxWidth: 1200)
        .padding(.horizontal, 80)
        .offset(x: showControls ? -160 : 0)
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
        VStack(spacing: 3) {
            HStack {
                Spacer()

                HStack(spacing: 20) {
                controlButton(
                    systemName: "backward.end.fill",
                    caption: nil,
                    focused: .previousChapter
                ) {
                    viewModel.previousChapter()
                    showControlsTemporarily()
                }

                controlButton(
                    systemName: "list.bullet",
                    caption: nil,
                    focused: .chapterList
                ) {
                    showChapterList = true
                    showControlsTemporarily()
                }

                controlButton(
                    systemName: "speedometer",
                    caption: nil,
                    focused: .speed
                ) {
                    showSpeedPicker = true
                    showControlsTemporarily()
                }

                controlButton(
                    systemName: "forward.end.fill",
                    caption: nil,
                    focused: .nextChapter
                ) {
                    viewModel.nextChapter()
                    showControlsTemporarily()
                }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            progressBar
        }
        .transition(.opacity)
    }

    private var progressBar: some View {
        let isFocused = focusedControl == .progressBar
        let displayProgress = (isScrubbing || isScrubSettling)
            ? scrubProgress
            : viewModel.chapterProgress
        return DirectionalPressButton(
            onSelect: {
                viewModel.playPause()
                showControlsTemporarily()
            },
            onMove: { direction in
                handleProgressBarMove(direction)
            },
            onScrub: { progress, state in
                handleProgressBarScrub(progress, state: state)
            },
            currentProgress: displayProgress,
            scrubScale: 0.4,
            scrubActivationProgress: 0.25
        ) {
            ProgressBarContent(
                progress: displayProgress,
                currentTime: viewModel.currentTimeFormatted,
                duration: viewModel.chapterDurationFormatted,
                isFocused: isFocused
            )
        }
        .focused($focusedControl, equals: .progressBar)
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

    private func handleBackgroundMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up, .down:
            showControlsTemporarily()
            focusedControl = .progressBar
        case .left, .right:
            break
        @unknown default:
            break
        }
    }

    private func handleProgressBarMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            viewModel.previousSentence()
            showControlsTemporarily()
        case .right:
            viewModel.nextSentence()
            showControlsTemporarily()
        case .up, .down:
            break
        @unknown default:
            break
        }
    }

    private func handleProgressBarScrub(
        _ progress: Double,
        state: UIGestureRecognizer.State
    ) {
        let clamped = min(max(progress, 0), 1)
        switch state {
        case .began, .changed:
            scrubSettleTask?.cancel()
            scrubSettleTask = nil
            isScrubSettling = false
            if !isScrubbing {
                scrubProgress = viewModel.chapterProgress
            }
            isScrubbing = true
            scrubProgress = clamped
            showControlsTemporarily()
        case .ended, .cancelled, .failed:
            if isScrubbing {
                let target = scrubProgress
                isScrubbing = false
                isScrubSettling = true
                scrubTargetProgress = target
                seekToChapterProgress(target)
                scheduleScrubSettleTimeout()
            }
        default:
            break
        }
    }

    private func scheduleScrubSettleTimeout() {
        scrubSettleTask?.cancel()
        scrubSettleTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isScrubSettling = false
        }
    }

    private func clearScrubSettlingIfNeeded(for progress: Double) {
        guard isScrubSettling else { return }
        let delta = abs(progress - scrubTargetProgress)
        if delta < 0.002 {
            scrubSettleTask?.cancel()
            scrubSettleTask = nil
            isScrubSettling = false
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
            if viewModel.isPlaying && !isScrubbing && !isScrubSettling {
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

    private func scrollToCurrent(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        consumeForce: Bool = true
    ) {
        guard let targetIndex = viewModel.scrollTargetIndex(
            for: viewModel.currentEntryIndex
        ) else {
            return
        }
        let shouldAnimate = animated && !forceInstantScroll
        let action = { proxy.scrollTo(targetIndex, anchor: .center) }
        if shouldAnimate {
            withAnimation(.smooth(duration: 0.5)) {
                action()
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
            }
        }
        if forceInstantScroll && consumeForce {
            forceInstantScroll = false
        }
    }

    private func controlButton(
        systemName: String,
        caption: String?,
        focused: FocusedControl,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedControl == focused
        return VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 20))
            }
            .buttonStyle(PlayerControlButtonStyle())
            .focused($focusedControl, equals: focused)

            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(
                    caption == nil
                        ? Color.clear
                        : Color.white.opacity(isFocused ? 0.9 : 0.7)
                )
        }
    }

}

private enum FocusedControl: Hashable {
    case progressBar
    case chapterList
    case previousChapter
    case nextChapter
    case speed
}

private struct PlayerControlButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .frame(width: isLarge ? 86 : 60, height: isLarge ? 86 : 60)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? .white : .white.opacity(0.2))
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

private struct ProgressBarContent: View {
    let progress: Double
    let currentTime: String
    let duration: String
    let isFocused: Bool

    var body: some View {
        let barHeight: CGFloat = isFocused ? 12 : 8
        let handleSize: CGFloat = isFocused ? 18 : 0

        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(height: barHeight)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white)
                        .scaleEffect(x: max(0.001, progress), y: 1, anchor: .leading)
                }
                .clipShape(Capsule())
                .overlay {
                    GeometryReader { proxy in
                        let clampedProgress = min(max(progress, 0), 1)
                        let xPosition = max(
                            handleSize / 2,
                            min(proxy.size.width - handleSize / 2, proxy.size.width * clampedProgress)
                        )
                        Circle()
                            .fill(.white)
                            .frame(width: handleSize, height: handleSize)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                            .position(x: xPosition, y: proxy.size.height / 2)
                            .opacity(isFocused ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isFocused)

            HStack {
                Text(currentTime)
                Spacer()
                Text(duration)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }
}

// Workaround: tvOS 18 drops the first directional press on onMoveCommand for the
// silver Siri Remote, so we intercept arrow presses in UIKit instead.
// https://developer.apple.com/forums/thread/764582
private struct DirectionalPressButton<Label: View>: UIViewRepresentable {
    var onSelect: () -> Void
    var onMove: (MoveCommandDirection) -> Void
    var onScrub: (Double, UIGestureRecognizer.State) -> Void
    var currentProgress: Double
    var scrubScale: CGFloat
    var scrubActivationProgress: Double
    var label: Label

    init(
        onSelect: @escaping () -> Void,
        onMove: @escaping (MoveCommandDirection) -> Void,
        onScrub: @escaping (Double, UIGestureRecognizer.State) -> Void,
        currentProgress: Double,
        scrubScale: CGFloat,
        scrubActivationProgress: Double,
        @ViewBuilder label: () -> Label
    ) {
        self.onSelect = onSelect
        self.onMove = onMove
        self.onScrub = onScrub
        self.currentProgress = currentProgress
        self.scrubScale = scrubScale
        self.scrubActivationProgress = scrubActivationProgress
        self.label = label()
    }

    func makeUIView(context: Context) -> PressButton {
        let button = PressButton()
        button.onSelect = onSelect
        button.onMove = onMove
        button.onScrub = onScrub
        button.currentProgress = currentProgress
        button.scrubScale = scrubScale
        button.scrubActivationProgress = scrubActivationProgress
        button.backgroundColor = .clear
        button.contentHorizontalAlignment = .fill
        button.contentVerticalAlignment = .fill
        button.addTarget(button, action: #selector(PressButton.handlePrimaryAction), for: .primaryActionTriggered)

        let host = UIHostingController(rootView: label)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        button.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: button.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        context.coordinator.host = host

        return button
    }

    func updateUIView(_ uiView: PressButton, context: Context) {
        uiView.onSelect = onSelect
        uiView.onMove = onMove
        uiView.onScrub = onScrub
        uiView.currentProgress = currentProgress
        uiView.scrubScale = scrubScale
        uiView.scrubActivationProgress = scrubActivationProgress
        context.coordinator.host?.rootView = label
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PressButton,
        context: Context
    ) -> CGSize? {
        guard let host = context.coordinator.host else { return nil }
        let targetWidth = proposal.width ?? UIScreen.main.bounds.width
        let size = host.sizeThatFits(
            in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var host: UIHostingController<Label>?
    }
}

private final class PressButton: UIButton {
    var onSelect: (() -> Void)?
    var onMove: ((MoveCommandDirection) -> Void)?
    var onScrub: ((Double, UIGestureRecognizer.State) -> Void)?
    var currentProgress: Double = 0
    var scrubScale: CGFloat = 0.4
    var scrubActivationProgress: Double = 0.1
    private var panStartProgress: CGFloat = 0
    private var panActivationOffset: CGFloat = 0
    private var scrubActivated = false
    private let panRecognizer = UIPanGestureRecognizer()

    override var canBecomeFocused: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGestures()
    }

    private func configureGestures() {
        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        panRecognizer.cancelsTouchesInView = false
        if #available(tvOS 14.0, *) {
            panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        }
        addGestureRecognizer(panRecognizer)
    }

    @objc func handlePrimaryAction() {
        onSelect?()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard bounds.width > 0 else { return }
        switch recognizer.state {
        case .began:
            panStartProgress = CGFloat(currentProgress)
            panActivationOffset = 0
            scrubActivated = false
        case .changed, .ended, .cancelled, .failed:
            let translation = recognizer.translation(in: self)
            if !scrubActivated {
                let requiredTranslation = CGFloat(scrubActivationProgress)
                    * bounds.width
                    / max(scrubScale, 0.01)
                if abs(translation.x) < requiredTranslation {
                    if recognizer.state != .ended {
                        return
                    }
                } else {
                    scrubActivated = true
                    panActivationOffset = translation.x > 0
                        ? requiredTranslation
                        : -requiredTranslation
                }
            }
            guard scrubActivated else { return }
            let adjustedTranslation = translation.x - panActivationOffset
            let delta = (adjustedTranslation / bounds.width) * scrubScale
            let progress = min(max(panStartProgress + delta, 0), 1)
            onScrub?(progress, recognizer.state)
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                scrubActivated = false
            }
        default:
            break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .leftArrow:
                onMove?(.left)
                return
            case .rightArrow:
                onMove?(.right)
                return
            case .upArrow, .downArrow:
                break
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
