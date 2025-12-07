#if os(watchOS)
import SwiftUI

struct WatchPlayerView: View {
    @State private var viewModel = WatchPlayerViewModel()
    @State private var showingPlayer = false

    let book: WatchBookEntry

    var body: some View {
        Group {
            if showingPlayer {
                playerContent
            } else {
                ChapterListView(viewModel: viewModel) { sectionIndex in
                    Task {
                        await viewModel.jumpToChapter(sectionIndex)
                        showingPlayer = true
                    }
                }
            }
        }
        .task {
            await viewModel.loadBook(book)
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    private var playerContent: some View {
        TabView {
            AudioControlsPage(viewModel: viewModel)
            TextReaderPage(viewModel: viewModel)
        }
        .tabViewStyle(.verticalPage)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    showingPlayer = false
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
        }
    }
}

// MARK: - Chapter List View

private struct ChapterListView: View {
    @Bindable var viewModel: WatchPlayerViewModel
    let onSelectChapter: (Int) -> Void

    var body: some View {
        List {
            ForEach(viewModel.chapters) { chapter in
                Button {
                    onSelectChapter(chapter.index)
                } label: {
                    HStack {
                        Text(chapter.label)
                            .lineLimit(2)
                        Spacer()
                        if chapter.index == viewModel.currentSectionIndex {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chapters")
    }
}

// MARK: - Audio Controls Page

private struct AudioControlsPage: View {
    @Bindable var viewModel: WatchPlayerViewModel
    @State private var crownVolume: Double = 1.0
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 6) {
                headerSection
                Spacer()
                controlsSection
                Spacer()
                progressSection
                Image(systemName: "chevron.compact.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack {
                volumeSidebar
                Spacer()
                    .frame(height: 50)
            }
        }
        .padding(.horizontal, 4)
        .focusable(true)
        .focused($isFocused)
        .digitalCrownRotation(
            detent: $crownVolume,
            from: 0, through: 1,
            by: 0.02,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownVolume) { _, newValue in
            viewModel.setVolume(newValue)
        }
        .onAppear {
            crownVolume = viewModel.volume
            isFocused = true
        }
    }

    private var headerSection: some View {
        VStack(spacing: 2) {
            Text(viewModel.bookTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(viewModel.chapterTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.skipBackward()
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.playPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 2) {
            ProgressView(value: viewModel.chapterProgress)
                .progressViewStyle(.linear)

            HStack {
                Text(viewModel.currentTimeFormatted)
                Spacer()
                Text(viewModel.chapterDurationFormatted)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var volumeSidebar: some View {
        VStack(spacing: 4) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                    Capsule()
                        .fill(viewModel.isMuted ? Color.red : Color.accentColor)
                        .frame(height: geo.size.height * (viewModel.isMuted ? 0 : viewModel.volume))
                }
            }
            .frame(width: 6)

            Button {
                viewModel.toggleMute()
            } label: {
                Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(viewModel.isMuted ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 20)
    }

}

// MARK: - Text Reader Page

private struct TextReaderPage: View {
    @Bindable var viewModel: WatchPlayerViewModel

    var body: some View {
        ScrollView {
            Text(viewModel.currentLineText)
                .font(.body)
            + Text(viewModel.nextLineText.isEmpty ? "" : " ")
            + Text(viewModel.nextLineText)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
    }
}
#endif
