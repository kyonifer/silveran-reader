import SwiftUI

public struct ChaptersButton: View {
    private let chapters: [ChapterItem]
    private let selectedChapterId: String?
    private let onChapterSelected: (String) -> Void
    private let backgroundColor: Color
    private let foregroundColor: Color
    private let transparency: Double
    private let showLabel: Bool
    private let buttonSize: CGFloat
    private let showBackground: Bool

    @State private var showSheet = false

    public init(
        chapters: [ChapterItem],
        selectedChapterId: String? = nil,
        onChapterSelected: @escaping (String) -> Void,
        backgroundColor: Color = Color.secondary,
        foregroundColor: Color = Color.primary,
        transparency: Double = 1.0,
        showLabel: Bool = true,
        buttonSize: CGFloat = 38,
        showBackground: Bool = true
    ) {
        self.chapters = chapters
        self.selectedChapterId = selectedChapterId
        self.onChapterSelected = onChapterSelected
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.transparency = transparency
        self.showLabel = showLabel
        self.buttonSize = buttonSize
        self.showBackground = showBackground
    }

    public var body: some View {
        VStack(spacing: 6) {
            #if os(iOS)
            Button(action: { showSheet = true }) {
                Image(systemName: "list.bullet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(foregroundColor.opacity(transparency))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Group {
                            if showBackground {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(backgroundColor.opacity(0.12 * transparency))
                            }
                        }
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSheet) {
                chaptersSheet
            }
            #else
            Menu {
                ForEach(chapters, id: \.id) { chapter in
                    Button(action: {
                        onChapterSelected(chapter.href)
                    }) {
                        HStack {
                            Text(String(repeating: "  ", count: chapter.level) + chapter.label)
                            if selectedChapterId == chapter.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(foregroundColor.opacity(transparency))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Group {
                            if showBackground {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(backgroundColor.opacity(0.12 * transparency))
                            }
                        }
                    )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            #endif

            if showLabel {
                Text("Chapters")
                    .font(.footnote)
                    .foregroundStyle(foregroundColor.opacity(0.7 * transparency))
            }
        }
    }

    #if os(iOS)
    private var chaptersSheet: some View {
        NavigationStack {
            List(chapters, id: \.id) { chapter in
                Button(action: {
                    onChapterSelected(chapter.href)
                    showSheet = false
                }) {
                    HStack {
                        Text(String(repeating: "  ", count: chapter.level))
                            .font(.system(size: 1))
                        Text(chapter.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedChapterId == chapter.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    #endif
}
