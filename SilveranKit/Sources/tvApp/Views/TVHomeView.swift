import SilveranKitAppModel
import SilveranKitCommon
import SwiftUI

struct TVHomeView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Binding var navigationPath: NavigationPath

    private var currentlyReading: [BookMetadata] {
        Array(mediaViewModel.itemsByStatus(
            "Reading",
            sortBy: .recentPositionUpdate,
            limit: .max
        ).filter { $0.hasAvailableReadaloud }.prefix(12))
    }

    private var startReading: [BookMetadata] {
        Array(mediaViewModel.itemsByStatus(
            "To read",
            sortBy: .recentlyAdded,
            limit: .max
        ).filter { $0.hasAvailableReadaloud }.prefix(12))
    }

    private var recentlyAdded: [BookMetadata] {
        Array(mediaViewModel.recentlyAddedItems(limit: .max)
            .filter { $0.hasAvailableReadaloud }.prefix(12))
    }

    private var completed: [BookMetadata] {
        Array(mediaViewModel.itemsByStatus(
            "Read",
            sortBy: .recentPositionUpdate,
            limit: .max
        ).filter { $0.hasAvailableReadaloud }.prefix(12))
    }

    private var hasAnyContent: Bool {
        !currentlyReading.isEmpty || !startReading.isEmpty || !recentlyAdded.isEmpty || !completed.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isDisconnected {
                    disconnectedView
                } else if !mediaViewModel.isReady {
                    loadingView
                } else if !hasAnyContent {
                    emptyStateView
                } else {
                    sectionsView
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            Text("Loading library...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text("No Books Available")
                .font(.title)
            Text("Add books to your library to see them here")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if !currentlyReading.isEmpty {
                    TVHomeSectionView(
                        title: "Currently Reading",
                        books: currentlyReading,
                        viewModel: mediaViewModel
                    )
                }

                if !startReading.isEmpty {
                    TVHomeSectionView(
                        title: "Start Reading",
                        books: startReading,
                        viewModel: mediaViewModel
                    )
                }

                if !recentlyAdded.isEmpty {
                    TVHomeSectionView(
                        title: "Recently Added",
                        books: recentlyAdded,
                        viewModel: mediaViewModel
                    )
                }

                if !completed.isEmpty {
                    TVHomeSectionView(
                        title: "Completed",
                        books: completed,
                        viewModel: mediaViewModel
                    )
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
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
        await mediaViewModel.refreshMetadata(source: "TVHomeView")
    }
}

private struct TVHomeSectionView: View {
    let title: String
    let books: [BookMetadata]
    let viewModel: MediaViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
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
                .padding(.vertical, 35)
            }
        }
    }

    private func isBookDownloaded(_ book: BookMetadata) -> Bool {
        viewModel.isCategoryDownloaded(.synced, for: book)
            || viewModel.isCategoryDownloaded(.audio, for: book)
    }

    private func downloadProgress(for book: BookMetadata) -> Double? {
        if viewModel.isCategoryDownloadInProgress(for: book, category: .synced) {
            return viewModel.downloadProgressFraction(for: book, category: .synced)
        }
        if viewModel.isCategoryDownloadInProgress(for: book, category: .audio) {
            return viewModel.downloadProgressFraction(for: book, category: .audio)
        }
        return nil
    }
}
