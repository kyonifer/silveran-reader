import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct TVBookDetailView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let book: BookMetadata
    @State private var navigateToPlayer = false

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            coverImage
            bookDetails
            Spacer()
        }
        .padding(80)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $navigateToPlayer) {
            TVPlayerView(book: book)
        }
    }

    private var coverImage: some View {
        let variant = mediaViewModel.coverVariant(for: book)
        let coverState = mediaViewModel.coverState(for: book, variant: variant)

        return Group {
            if let image = coverState.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholderCover
            }
        }
        .frame(width: 400, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
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
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if let author = book.creators?.first?.name {
                    Text("by \(author)")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            let progress = mediaViewModel.progress(for: book.id)
            if progress > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading Progress")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .frame(width: 300)
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if book.hasAvailableReadaloud {
                readaloudActions
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
    }

    private var readaloudActions: some View {
        let isDownloaded = mediaViewModel.isCategoryDownloaded(.synced, for: book)
        let isDownloading = mediaViewModel.isCategoryDownloadInProgress(
            for: book,
            category: .synced
        )
        let progress = mediaViewModel.downloadProgressFraction(for: book, category: .synced)

        return HStack(spacing: 24) {
            if isDownloaded {
                Button {
                    navigateToPlayer = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: book, category: .synced)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if isDownloading {
                if let progress {
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 200)
                        Text("Downloading... \(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                Button(role: .destructive) {
                    mediaViewModel.cancelDownload(for: book, category: .synced)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            } else {
                Button {
                    mediaViewModel.startDownload(for: book, category: .synced)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func taskIdentifier(variant: MediaViewModel.CoverVariant) -> String {
        let variantId = variant == .standard ? "standard" : "audio"
        return "\(book.id)-\(variantId)-\(mediaViewModel.connectionStatus)"
    }
}
