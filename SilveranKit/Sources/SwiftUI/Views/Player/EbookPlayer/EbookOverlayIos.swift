import SwiftUI

/// iOS stats overlay showing progress and time remaining
/// Supports both bottom position (default) and top position (when mini player covers bottom)
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
    let positionAtTop: Bool
    let onTogglePlaying: () -> Void

    private var hasTimeStatsToDisplay: Bool {
        hasAudioNarration && (showTimeRemainingInBook || showTimeRemainingInChapter)
    }

    private var hasBookStatsToDisplay: Bool {
        (showProgress && bookFraction != nil)
            || (showPageNumber && currentPage != nil && totalPages != nil && totalPages! > 0)
    }

    var body: some View {
        if positionAtTop {
            topPositionedLayout
        } else {
            bottomPositionedLayout
        }
    }

    // MARK: - Top Position Layout (when mini player covers bottom)

    private var topPositionedLayout: some View {
        VStack {
            HStack(alignment: .top) {
                if hasBookStatsToDisplay {
                    bookStatsWithIcons
                }
                Spacer()
                if hasTimeStatsToDisplay {
                    timeStatsWithIcons
                }
            }
            .padding(.horizontal, 38)
            .padding(.top, 16)

            Spacer()
        }
        .ignoresSafeArea(.all)
    }

    private var bookStatsWithIcons: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showProgress, let bookFraction = bookFraction {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                    Text(formatPercent(bookFraction))
                        .font(.caption2.monospacedDigit())
                }
                .foregroundColor(.gray.opacity(overlayTransparency))
            }

            if showPageNumber, let current = currentPage, let total = totalPages, total > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                    Text("Page \(current) of \(total)")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundColor(.gray.opacity(overlayTransparency))
            }
        }
    }

    private var timeStatsWithIcons: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if showTimeRemainingInBook {
                HStack(spacing: 4) {
                    Text(formatTimeHoursMinutes(bookTimeRemaining))
                        .font(.caption2.monospacedDigit())
                    Image(systemName: "book.fill")
                        .font(.caption2)
                }
                .foregroundColor(.gray.opacity(overlayTransparency))
            }

            if showTimeRemainingInChapter {
                HStack(spacing: 4) {
                    Text(formatTimeMinutesSeconds(chapterTimeRemaining))
                        .font(.caption2.monospacedDigit())
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                }
                .foregroundColor(.gray.opacity(overlayTransparency))
            }
        }
    }

    // MARK: - Bottom Position Layout (original/default)

    private var bottomPositionedLayout: some View {
        VStack {
            Spacer()
            ZStack {
                HStack {
                    if hasBookStatsToDisplay {
                        bookStatsWithIcons
                    }
                    Spacer()
                    if hasTimeStatsToDisplay {
                        timeStatsWithIcons
                    }
                }

                if hasAudioNarration {
                    playPauseButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea(.all)
    }

    // MARK: - Shared Components

    private var playPauseButton: some View {
        Button(action: onTogglePlaying) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20))
                .foregroundColor(.gray.opacity(overlayTransparency))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Formatting

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", max(min(value, 1), 0) * 100)
    }
}
