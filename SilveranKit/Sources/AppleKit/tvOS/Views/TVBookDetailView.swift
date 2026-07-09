#if os(tvOS)
import SilveranKit
import SwiftUI

struct TVBookDetailView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let book: BookMetadata
    @State private var navigateToPlayer = false

    var body: some View {
        ZStack {
            backgroundArtwork

            HStack(alignment: .top, spacing: 68) {
                coverImage
                bookDetails
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 100)
            .padding(.top, 132)
            .padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $navigateToPlayer) {
            TVPlayerView(book: book)
        }
    }

    private var backgroundArtwork: some View {
        let variant = mediaViewModel.coverVariant(for: book)
        let coverState = mediaViewModel.coverState(for: book, variant: variant)

        return ZStack {
            if let image = coverState.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .blur(radius: 36)
                    .saturation(0.75)
                    .opacity(0.45)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.66),
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )
        }
        .ignoresSafeArea()
    }

    private var coverImage: some View {
        let variant = mediaViewModel.coverVariant(for: book)
        let coverState = mediaViewModel.coverState(for: book, variant: variant)

        return Group {
            if let image = coverState.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholderCover
            }
        }
        .frame(width: 360, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.55), radius: 20, x: 0, y: 14)
        .task(id: taskIdentifier(variant: variant)) {
            mediaViewModel.ensureCoverLoaded(for: book, variant: variant)
        }
    }

    private var placeholderCover: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: "book.closed")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
        }
    }

    private var bookDetails: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text(book.title)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                if let subtitle = trimmed(book.subtitle) {
                    Text(subtitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)
                }

                if hasMetadata {
                    metadataLines
                }
            }

            if let description = cleanedDescription {
                Text(description)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(3)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let progress = mediaViewModel.progress(for: book.id)
            progressBlock(progress: progress)

            if book.hasAvailableReadaloud {
                readaloudActions
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private func progressBlock(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Reading Progress: \(Int(progress * 100))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)

            ProgressView(value: progress)
                .frame(width: 360)
                .tint(.white)
                .opacity(progress > 0 ? 1 : 0.42)
        }
    }

    private var readaloudActions: some View {
        let isDownloaded = mediaViewModel.isCategoryDownloaded(.synced, for: book)
        let isDownloading = mediaViewModel.isCategoryDownloadInProgress(
            for: book,
            category: .synced,
        )
        let progress = mediaViewModel.downloadProgressFraction(for: book, category: .synced)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                primaryReadaloudButton(isDownloaded: isDownloaded, isDownloading: isDownloading)

                if isDownloaded {
                    Button {
                        mediaViewModel.deleteDownload(for: book, category: .synced)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(width: 236)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if isDownloading {
                    Button {
                        mediaViewModel.cancelDownload(for: book, category: .synced)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .frame(width: 236)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .frame(height: 74, alignment: .leading)

            downloadProgressView(progress: progress)
                .opacity(isDownloading ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.18), value: isDownloading)
    }

    private func primaryReadaloudButton(isDownloaded: Bool, isDownloading: Bool) -> some View {
        Group {
            if isDownloaded {
                Button {
                    navigateToPlayer = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(width: 236)
                }
            } else if isDownloading {
                Button {
                } label: {
                    Label("Downloading", systemImage: "arrow.down.circle")
                        .frame(width: 236)
                }
                .disabled(true)
            } else {
                Button {
                    mediaViewModel.startDownload(for: book, category: .synced)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(width: 236)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func downloadProgressView(progress: Double?) -> some View {
        let fraction = min(max(progress ?? 0, 0), 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Download Progress")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.64))

                Spacer(minLength: 24)

                Text("\(Int(fraction * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 80, alignment: .trailing)
            }
            .frame(width: 500)

            ProgressView(value: fraction)
                .frame(width: 500)
                .tint(.white)
        }
        .frame(width: 500, alignment: .leading)
    }

    private var cleanedDescription: String? {
        guard let description = trimmed(book.description) else { return nil }
        return trimmed(BookDescriptionText.plain(from: description))
    }

    private var authorLine: String? {
        creatorLine(book.authors) ?? creatorLine(book.creators)
    }

    private var narratorLine: String? {
        creatorLine(book.narrators)
    }

    private var ratingLine: String? {
        guard let rating = book.rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    private var seriesLine: String? {
        guard let series = book.series?.first else { return nil }
        if let position = series.formattedPosition {
            return "\(series.name), #\(position)"
        }
        return series.name
    }

    private var hasMetadata: Bool {
        narratorLine != nil || authorLine != nil || seriesLine != nil || ratingLine != nil
    }

    private var metadataLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let narratorLine {
                metadataLine(label: "Narrated by", value: narratorLine)
            }

            if let authorLine {
                metadataLine(label: "Written by", value: authorLine)
            }

            if let seriesLine {
                metadataLine(label: "Part of", value: seriesLine)
            }

            if let ratingLine {
                metadataLine(label: "Rating", value: "\(ratingLine) stars")
            }
        }
        .font(.system(size: 21, weight: .medium))
        .lineLimit(1)
    }

    private func metadataLine(label: String, value: String) -> Text {
        Text("\(label) ")
            .foregroundStyle(.white.opacity(0.42))
            + Text(value)
            .foregroundStyle(.white.opacity(0.76))
    }

    private func creatorLine(_ creators: [BookCreator]?) -> String? {
        let names = creators?.compactMap { trimmed($0.name) } ?? []
        guard !names.isEmpty else { return nil }
        return names.prefix(2).joined(separator: ", ")
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func taskIdentifier(variant: MediaViewModel.CoverVariant) -> String {
        let variantId = variant == .standard ? "standard" : "audio"
        return "\(book.id)-\(variantId)-\(mediaViewModel.connectionStatus)"
    }
}
#endif
