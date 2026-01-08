import SwiftUI

struct TVChapterListView: View {
    let viewModel: TVPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.chapters) { chapter in
                Button {
                    Task {
                        await viewModel.jumpToChapter(chapter.index)
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(chapter.label)
                            .font(.headline)

                        Spacer()

                        if chapter.index == viewModel.currentSectionIndex {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                // Workaround: default button style causes blurred text on focus in tvOS Lists
                .buttonStyle(.plain)
            }
            .navigationTitle("Chapters")
        }
    }
}
