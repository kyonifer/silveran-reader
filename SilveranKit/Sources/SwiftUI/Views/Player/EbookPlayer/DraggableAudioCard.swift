import SwiftUI

#if os(iOS)
struct DraggableAudioCard<FullContent: View>: View {
    @Binding var isPresented: Bool
    let alwaysShow: Bool
    let collapseTrigger: Int

    let bookTitle: String?
    let coverArt: Image?
    let chapterTitle: String?
    let isPlaying: Bool
    let chapterProgress: Double
    let chapterElapsedSeconds: TimeInterval?
    let chapterTotalSeconds: TimeInterval?
    let playbackRate: Double
    let hasAudioNarration: Bool
    let chapters: [ChapterItem]
    let selectedChapterHref: String?
    let sleepTimerActive: Bool
    let sleepTimerRemaining: TimeInterval?
    let sleepTimerType: SleepTimerType?

    let onPlayPause: () -> Void
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onProgressSeek: ((Double) -> Void)?
    let onPlaybackRateChange: (Double) -> Void
    let onChapterSelected: (String) -> Void
    let onSleepTimerStart: (TimeInterval?, SleepTimerType) -> Void
    let onSleepTimerCancel: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder let fullContent: () -> FullContent

    enum CardState {
        case compact
        case expanded
    }

    @State private var cardState: CardState = .compact
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false
    @State private var sliderValue: Double = 0
    @State private var isDraggingSlider = false

    private let compactHeight: CGFloat = 50
    private let expandedFraction: CGFloat = 1.0
    private let dragThreshold: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height
            let safeAreaBottom = geometry.safeAreaInsets.bottom
            let expandedHeight = screenHeight * expandedFraction

            let targetHeight: CGFloat =
                switch cardState {
                    case .compact: compactHeight + safeAreaBottom
                    case .expanded: expandedHeight
                }

            let currentHeight = max(0, min(expandedHeight, targetHeight - dragOffset))

            ZStack(alignment: .bottom) {
                if isPresented {
                    VStack(spacing: 0) {
                        if cardState != .compact {
                            dragHandleView(compact: false)
                        }

                        if cardState == .expanded {
                            fullContent()
                                .transition(.opacity)
                        } else {
                            compactPlayerContent
                                .transition(.opacity)
                        }

                        Spacer(minLength: safeAreaBottom)
                    }
                    .overlay(alignment: .top) {
                        if cardState == .compact {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 36, height: 5)
                                .padding(.top, 22)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if cardState == .expanded {
                            Button(action: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    cardState = .compact
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                        }
                    }
                    .frame(height: currentHeight)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .modifier(GlassEffectModifier())
                    .gesture(
                        DragGesture()
                            .updating($isDragging) { _, state, _ in
                                state = true
                            }
                            .onChanged { value in
                                dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                handleDragEnd(
                                    translation: value.translation.height,
                                    velocity: value.predictedEndTranslation.height
                                        - value.translation.height,
                                    screenHeight: screenHeight
                                )
                            }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cardState)
        .animation(.interactiveSpring(), value: dragOffset)
        .onChange(of: isDragging) { _, newValue in
            if !newValue && dragOffset != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = 0
                }
            }
        }
        .onChange(of: chapterProgress) { _, newValue in
            if !isDraggingSlider {
                sliderValue = newValue
            }
        }
        .onChange(of: collapseTrigger) { _, _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardState = .compact
            }
        }
        .onAppear {
            sliderValue = chapterProgress
        }
    }

    private func dragHandleView(compact: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, compact ? 10 : 12)
            .padding(.bottom, compact ? 6 : 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private var compactPlayerContent: some View {
        HStack(spacing: 12) {
            if let coverArt = coverArt {
                coverArt
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "book.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title = bookTitle {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }

                if let chapter = chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if hasAudioNarration {
                HStack(spacing: 15) {
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            cardState = .expanded
                        }
                    }) {
                        Image(systemName: "headphones")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    PlaybackRateButton(
                        currentRate: playbackRate,
                        onRateChange: onPlaybackRateChange,
                        showLabel: true,
                        buttonSize: 36,
                        showBackground: false,
                        compactLabel: true,
                        iconFont: .title3
                    )

                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 54, height: 54)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }

    private func handleDragEnd(translation: CGFloat, velocity: CGFloat, screenHeight: CGFloat) {
        let velocityThreshold: CGFloat = 500

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dragOffset = 0

            switch cardState {
                case .compact:
                    let isSwipeUp = translation < -dragThreshold || velocity < -velocityThreshold
                    let isSwipeDown = translation > dragThreshold || velocity > velocityThreshold
                    if isSwipeUp {
                        cardState = .expanded
                    } else if isSwipeDown && !alwaysShow {
                        isPresented = false
                    }

                case .expanded:
                    let isSwipeDown = translation > dragThreshold || velocity > velocityThreshold
                    if isSwipeDown {
                        cardState = .compact
                    }
            }
        }
    }
}

private struct GlassEffectModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private let shape = UnevenRoundedRectangle(
        topLeadingRadius: 16,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 16,
        style: .continuous
    )

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(
                    shape
                        .fill(Color(uiColor: .systemBackground))
                )
                .clipShape(shape)
                .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        }
    }
}
#endif
