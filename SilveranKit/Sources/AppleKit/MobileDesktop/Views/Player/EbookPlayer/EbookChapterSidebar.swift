#if os(iOS) || os(macOS)
import SwiftUI

struct EbookChapterSidebar: View {
    let chapters: [ChapterItem]
    let selectedChapterId: String?
    let backgroundColor: Color
    let onChapterSelected: (ChapterItem) -> Void

    var body: some View {
        List {
            Section("Chapters") {
                ForEach(chapters, id: \.id) { chapter in
                    Button {
                        debugLog(
                            "[TOC-DEBUG] Sidebar button tapped: id=\(chapter.id) label=\"\(chapter.label)\""
                        )
                        onChapterSelected(chapter)
                    } label: {
                        Text(chapter.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(chapter.level) * 16)
                    .listRowBackground(
                        chapter.id == selectedChapterId
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(backgroundColor)
    }
}

#endif
