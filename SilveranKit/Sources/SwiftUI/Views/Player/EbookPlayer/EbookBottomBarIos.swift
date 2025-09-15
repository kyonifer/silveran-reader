import SwiftUI

private extension VerticalAlignment {
    struct IconCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let iconCenter = VerticalAlignment(IconCenter.self)
}

struct EbookBottomBarIos: View {
    let bookTitle: String?
    let coverArt: Image?
    let progressData: ProgressData?
    let playbackRate: Double
    let isPlaying: Bool
    let hasAudioNarration: Bool
    @Binding var chapterProgress: Double

    let onShowAudioSheet: () -> Void
    let onPlayPause: () -> Void
    let onProgressSeek: ((Double) -> Void)?

    @State private var isDraggingSlider = false
    @State private var draggedSliderValue: Double = 0.0
    @State private var seekDebounceUntil: Date?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if hasAudioNarration {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 36, height: 5)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }

                HStack(alignment: .center, spacing: 12) {
                    leftInfoSection
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, hasAudioNarration ? 0 : 12)
                .padding(.bottom, 16)
            }
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
            .contentShape(Rectangle())
            .onTapGesture {
                if hasAudioNarration {
                    onShowAudioSheet()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if hasAudioNarration && value.translation.height < -30 {
                            onShowAudioSheet()
                        }
                    }
            )

            if hasAudioNarration {
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.3))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .help("Play/pause")
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.all)
    }

    private var leftInfoSection: some View {
        HStack(alignment: .top, spacing: 8) {
            if let coverArt = coverArt {
                coverArt
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .padding(.leading, 5)
            } else {
                Image(systemName: "book.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title = bookTitle {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }

                if let chapterLabel = progressData?.chapterLabel {
                    Text(chapterLabel)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                if let current = progressData?.chapterCurrentPage,
                   let total = progressData?.chapterTotalPages {
                    Text("pg. \(current)/\(total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var seekBar: some View {
        let sliderBinding = Binding(
            get: {
                if isDraggingSlider {
                    return draggedSliderValue
                }

                if let debounceUntil = seekDebounceUntil, Date() < debounceUntil {
                    return draggedSliderValue
                }

                let audioFraction = chapterAudioFraction(
                    current: progressData?.chapterCurrentSecondsAudio,
                    total: progressData?.chapterTotalSecondsAudio
                )
                let pagesFraction = chapterPagesFraction(
                    current: progressData?.chapterCurrentPage,
                    total: progressData?.chapterTotalPages
                )

                let fraction: Double
                if isPlaying, let audio = audioFraction {
                    fraction = audio
                } else if let pages = pagesFraction {
                    fraction = pages
                } else if let audio = audioFraction {
                    fraction = audio
                } else {
                    fraction = chapterProgress
                }

                return min(max(fraction, 0), 1)
            },
            set: { newValue in
                let clampedValue = min(max(newValue, 0), 1)
                isDraggingSlider = true
                draggedSliderValue = clampedValue
                chapterProgress = clampedValue
                onProgressSeek?(clampedValue)
            }
        )

        return VStack(alignment: .leading, spacing: 4) {
            Slider(value: sliderBinding, in: 0...1, onEditingChanged: { editing in
                isDraggingSlider = editing
                if editing {
                    seekDebounceUntil = nil
                    let audioFraction = chapterAudioFraction(
                        current: progressData?.chapterCurrentSecondsAudio,
                        total: progressData?.chapterTotalSecondsAudio
                    )
                    let pagesFraction = chapterPagesFraction(
                        current: progressData?.chapterCurrentPage,
                        total: progressData?.chapterTotalPages
                    )

                    let initialFraction: Double
                    if isPlaying, let audio = audioFraction {
                        initialFraction = audio
                    } else if let pages = pagesFraction {
                        initialFraction = pages
                    } else if let audio = audioFraction {
                        initialFraction = audio
                    } else {
                        initialFraction = chapterProgress
                    }

                    draggedSliderValue = min(max(initialFraction, 0), 1)
                } else {
                    seekDebounceUntil = Date().addingTimeInterval(0.5)
                }
            })
            .tint(Color.white.opacity(0.9))

            HStack {
                Text(formatOptionalTime(chapterElapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("-\(formatOptionalTime(chapterRemainingAtRate ?? rawRemaining)) (\(formatPlaybackRate(playbackRate)))")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text(formatOptionalTime(chapterTotal))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var chapterElapsed: TimeInterval? {
        normalizedSeconds(progressData?.chapterCurrentSecondsAudio)
    }

    private var chapterTotal: TimeInterval? {
        guard let elapsed = chapterElapsed,
              let total = normalizedSeconds(progressData?.chapterTotalSecondsAudio) else {
            return nil
        }
        return max(total, elapsed)
    }

    private var rawRemaining: TimeInterval? {
        guard let total = chapterTotal, let elapsed = chapterElapsed else {
            return nil
        }
        return max(total - elapsed, 0)
    }

    private var chapterRemainingAtRate: TimeInterval? {
        timeRemaining(atRate: playbackRate, total: chapterTotal, elapsed: chapterElapsed)
    }
}
