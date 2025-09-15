import SwiftUI

struct SeriesStackView: View {
    let books: [BookMetadata]
    let mediaKind: MediaKind
    let availableWidth: CGFloat
    let onSelect: (BookMetadata) -> Void
    let onInfo: (BookMetadata) -> Void
    @Environment(MediaViewModel.self) private var mediaViewModel

    private let coverHeight: CGFloat = 220
    private let minOverlapRatio: CGFloat = 0.0
    private let maxOverlapRatio: CGFloat = 0.90

    var body: some View {
        let safeAvailableWidth = max(availableWidth, 100)
        let layout = calculateLayout(availableWidth: safeAvailableWidth)

        ZStack(alignment: .leading) {
            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                coverView(for: book, index: index, layout: layout)
            }
        }
        .frame(width: layout.totalWidth, height: coverHeight, alignment: .leading)
    }

    private func coverView(for book: BookMetadata, index: Int, layout: LayoutInfo) -> some View {
        let coverVariant = mediaViewModel.coverVariant(for: book)
        let coverWidth = coverHeight * coverVariant.preferredAspectRatio
        let placeholderColor = Color(red: 56 / 255, green: 18 / 255, blue: 108 / 255)

        return ZStack {
            placeholderColor

            if let image = mediaViewModel.coverImage(for: book, variant: coverVariant) {
                image
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: coverWidth, height: coverHeight)
                    .clipped()
            }
        }
        .frame(width: coverWidth, height: coverHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(book)
        }
        .zIndex(Double(index))
        .offset(x: layout.offset(for: index), y: 0)
        .task {
            mediaViewModel.ensureCoverLoaded(for: book, variant: coverVariant)
        }
    }

    private func calculateLayout(availableWidth: CGFloat) -> LayoutInfo {
        guard !books.isEmpty else {
            return LayoutInfo(offsets: [], totalWidth: 0)
        }

        var coverWidths: [CGFloat] = []
        for book in books {
            let variant = mediaViewModel.coverVariant(for: book)
            let width = coverHeight * variant.preferredAspectRatio
            coverWidths.append(width)
        }

        guard books.count > 1 else {
            return LayoutInfo(offsets: [0], totalWidth: coverWidths[0])
        }

        let minVisibleRatio = 1.0 - minOverlapRatio
        let maxVisibleRatio = 1.0 - maxOverlapRatio

        let idealWidth =
            coverWidths.dropLast().reduce(0) { $0 + $1 * minVisibleRatio } + coverWidths.last!

        let maxCompressedWidth =
            coverWidths.dropLast().reduce(0) { $0 + $1 * maxVisibleRatio } + coverWidths.last!

        var offsets: [CGFloat] = []
        var currentOffset: CGFloat = 0
        var totalWidth: CGFloat

        if availableWidth >= idealWidth {
            for (index, width) in coverWidths.enumerated() {
                offsets.append(currentOffset)
                if index < coverWidths.count - 1 {
                    currentOffset += width * minVisibleRatio
                }
            }
            totalWidth = idealWidth
        } else if availableWidth <= maxCompressedWidth {
            for (index, width) in coverWidths.enumerated() {
                offsets.append(currentOffset)
                if index < coverWidths.count - 1 {
                    currentOffset += width * maxVisibleRatio
                }
            }
            totalWidth = maxCompressedWidth
        } else {
            let targetWidth = availableWidth
            let availableRange = idealWidth - maxCompressedWidth
            let progress = (targetWidth - maxCompressedWidth) / availableRange
            let visibleRatio = maxVisibleRatio + (minVisibleRatio - maxVisibleRatio) * progress

            for (index, width) in coverWidths.enumerated() {
                offsets.append(currentOffset)
                if index < coverWidths.count - 1 {
                    currentOffset += width * visibleRatio
                }
            }
            totalWidth = currentOffset + coverWidths.last!
        }

        return LayoutInfo(offsets: offsets, totalWidth: min(totalWidth, availableWidth))
    }

    private struct LayoutInfo {
        let offsets: [CGFloat]
        let totalWidth: CGFloat

        func offset(for index: Int) -> CGFloat {
            guard index < offsets.count else { return 0 }
            return offsets[index]
        }
    }
}
