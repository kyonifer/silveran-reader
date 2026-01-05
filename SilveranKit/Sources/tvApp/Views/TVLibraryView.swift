import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct TVLibraryView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Binding var navigationPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isDisconnected {
                    disconnectedView
                } else if !mediaViewModel.isReady {
                    loadingView
                } else {
                    booksGridView
                }
            }
            .navigationDestination(for: BookMetadata.self) { book in
                TVBookDetailView(book: book)
            }
        }
        .task {
            await refreshLibrary()
        }
    }

    private var disconnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text("Not Connected")
                .font(.title)
            Text("Configure server connection in Settings")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Loading server library...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var booksGridView: some View {
        let books = mediaViewModel.library.bookMetaData.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 30)
                ],
                spacing: 30
            ) {
                ForEach(books, id: \.uuid) { book in
                    NavigationLink(value: book) {
                        TVBookCardView(
                            book: book,
                            isDownloaded: isBookDownloaded(book),
                            downloadProgress: downloadProgress(for: book)
                        )
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 20)
            .padding(.bottom, 60)
        }
    }

    private func isBookDownloaded(_ book: BookMetadata) -> Bool {
        mediaViewModel.isCategoryDownloaded(.synced, for: book)
            || mediaViewModel.isCategoryDownloaded(.audio, for: book)
    }

    private func downloadProgress(for book: BookMetadata) -> Double? {
        if mediaViewModel.isCategoryDownloadInProgress(for: book, category: .synced) {
            return mediaViewModel.downloadProgressFraction(for: book, category: .synced)
        }
        if mediaViewModel.isCategoryDownloadInProgress(for: book, category: .audio) {
            return mediaViewModel.downloadProgressFraction(for: book, category: .audio)
        }
        return nil
    }

    private var isDisconnected: Bool {
        switch mediaViewModel.connectionStatus {
            case .disconnected, .error:
                return true
            case .connecting, .connected:
                return false
        }
    }

    private func refreshLibrary() async {
        let status = await StorytellerActor.shared.connectionStatus
        if status == .connected {
            let _ = await StorytellerActor.shared.fetchLibraryInformation()
        }
        await mediaViewModel.refreshMetadata(source: "TVLibraryView")
    }
}
