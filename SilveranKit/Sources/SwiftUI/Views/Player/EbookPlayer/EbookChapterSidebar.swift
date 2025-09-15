import SwiftUI

/// Chapter sidebar for ebook reader showing table of contents
struct EbookChapterSidebar: View {
    @Binding var selectedChapterId: Int?
    let bookStructure: [SectionInfo]
    let onChapterSelected: (Int?) -> Void

    private var chaptersWithIndices: [(index: Int, chapter: SectionInfo)] {
        bookStructure.enumerated().compactMap { index, chapter in
            guard chapter.label != nil else { return nil }
            return (index, chapter)
        }
    }

    var body: some View {
        List(selection: $selectedChapterId) {
            Section("Chapters") {
                ForEach(chaptersWithIndices, id: \.chapter.id) { item in
                    HStack {
                        Text(String(repeating: "  ", count: item.chapter.level ?? 0))
                            .font(.system(size: 1))
                        Text(item.chapter.label ?? "Untitled")
                    }
                    .tag(item.index)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 280)
        .onChange(of: selectedChapterId) { oldValue, newValue in
            debugLog("[EbookPlayerView] EbookChapterSidebar - selectedChapterId changed from \(oldValue?.description ?? "nil") to \(newValue?.description ?? "nil")")
            onChapterSelected(newValue)
        }
    }
}
