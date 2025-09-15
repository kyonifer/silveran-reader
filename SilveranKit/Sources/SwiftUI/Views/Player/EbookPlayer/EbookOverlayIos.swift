import SwiftUI

/// iOS stats overlay showing progress and time remaining when bottom bar is hidden
struct EbookOverlayIos: View {
    let showProgress: Bool
    let showTimeRemainingInBook: Bool
    let showTimeRemainingInChapter: Bool
    let showPageNumber: Bool
    let overlayTransparency: Double
    let bookFraction: Double?
    let bookTimeRemaining: TimeInterval?
    let chapterTimeRemaining: TimeInterval?
    let currentPage: Int?
    let totalPages: Int?
    let isPlaying: Bool
    let hasAudioNarration: Bool
    let onTogglePlaying: () -> Void

    private var hasLargeStatsToDisplay: Bool {
        (showTimeRemainingInBook && bookTimeRemaining != nil) ||
        (showTimeRemainingInChapter && chapterTimeRemaining != nil)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 0) {
                    HStack {
                        smallStatsSection
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)

                    if hasLargeStatsToDisplay {
                        largeStatsSection
                    }

                    HStack {
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)

            if hasAudioNarration {
                playPauseButton
            }
        }
        .ignoresSafeArea(.all)
    }

    private var smallStatsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showProgress, let bookFraction = bookFraction {
                Text(formatPercent(bookFraction))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.gray.opacity(overlayTransparency))
            }

            if showPageNumber, let current = currentPage, let total = totalPages, total > 0 {
                Text("Page \(current) of \(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.gray.opacity(overlayTransparency))
            }
        }
    }

    private var largeStatsSection: some View {
        VStack(alignment: .center, spacing: 2) {
            if showTimeRemainingInBook, let timeRemaining = bookTimeRemaining {
                Text("\(formatTimeHoursMinutes(timeRemaining)) in Book")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.gray.opacity(overlayTransparency))
            }

            if showTimeRemainingInChapter, let timeRemaining = chapterTimeRemaining {
                Text("\(formatTimeMinutesSeconds(timeRemaining)) in Chapter")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.gray.opacity(overlayTransparency))
            }
        }
    }

    private var playPauseButton: some View {
        Button(action: onTogglePlaying) {
            HStack(alignment: .bottom, spacing: 0) {
                Spacer()
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.gray.opacity(overlayTransparency))
                    .padding(.trailing, 25)
                    .padding(.bottom, 30)
            }
            .frame(width: 100, height: 100, alignment: .bottomTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", max(min(value, 1), 0) * 100)
    }

    private func formatTimeHoursMinutes(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatTimeMinutesSeconds(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m\(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}
