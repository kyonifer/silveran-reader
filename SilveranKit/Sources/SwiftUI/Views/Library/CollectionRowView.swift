import SwiftUI

struct CollectionRowView: View {
    let collection: BookCollectionSummary?
    let books: [BookMetadata]
    let mediaKind: MediaKind
    let coverPreference: CoverPreference
    let onTap: () -> Void
    @Environment(MediaViewModel.self) private var mediaViewModel

    private let rowHeight: CGFloat = 64
    private let coverSize: CGFloat = 48
    private let horizontalPadding: CGFloat = 12

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                coverStack
                    .frame(width: coverStackWidth, height: coverSize, alignment: .leading)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.75),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing,
                        )
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(collection?.name ?? "Unknown Collection")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .frame(height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private var coverStackWidth: CGFloat {
        coverSize * 0.67 + 2 * 12
    }

    @ViewBuilder
    private var coverStack: some View {
        let displayBooks = Array(books.prefix(3))
        let placeholderColor = Color(white: 0.2)

        ZStack(alignment: .leading) {
            ForEach(Array(displayBooks.enumerated()), id: \.offset) { index, book in
                let coverVariant = resolveCoverVariant(for: book)
                let aspectRatio = coverVariant.preferredAspectRatio
                let coverState = mediaViewModel.coverState(for: book, variant: coverVariant)
                let offset = CGFloat(index) * 12

                ZStack {
                    placeholderColor
                    if let image = coverState.image {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    }
                }
                .frame(width: coverSize * aspectRatio, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .stableCoverRendering()
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                .offset(x: offset)
                .zIndex(Double(index))
                .task {
                    mediaViewModel.ensureCoverLoaded(for: book, variant: coverVariant)
                }
                .onDisappear {
                    mediaViewModel.cancelCoverLoad(for: book, variant: coverVariant)
                }
            }
        }
    }

    private func resolveCoverVariant(for item: BookMetadata) -> MediaViewModel.CoverVariant {
        mediaViewModel.coverVariant(for: item, preference: coverPreference)
    }
}
