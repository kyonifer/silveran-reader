#if os(iOS)
import SwiftUI

struct iOSBookDetailView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                coverSection
                titleSection
                progressSection
                BookStatusSection(item: item)
                MediaGridDownloadSection(item: item)
                descriptionSection
                debugInfoSection
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .navigationTitle("Book Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var coverSection: some View {
        let variant = mediaViewModel.coverVariant(for: item)
        let image = mediaViewModel.coverImage(for: item, variant: variant)
        let placeholderColor = Color(white: 0.2)

        return HStack {
            Spacer()
            ZStack {
                placeholderColor
                if let image {
                    image
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                }
            }
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8)
            .task {
                mediaViewModel.ensureCoverLoaded(for: item, variant: variant)
            }
            Spacer()
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title2)
                .fontWeight(.bold)
                .textSelection(.enabled)

            if let series = item.series?.first {
                HStack(spacing: 4) {
                    Text(series.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let position = series.position {
                        Text("•")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Book \(position)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }

            if let author = item.authors?.first?.name {
                Text("Written by \(author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let narrator = item.narrators?.first?.name {
                Text("Narrated by \(narrator)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var progressSection: some View {
        let progress = mediaViewModel.progress(for: item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reading Progress")
                    .font(.callout)
                    .fontWeight(.medium)
                SyncStatusIndicators(bookId: item.id)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.45), value: progress)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = item.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(htmlToPlainText(description))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var debugInfoSection: some View {
        if let positionUpdatedAt = currentItem.position?.updatedAt {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last Read Date")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(formatDate(positionUpdatedAt))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func htmlToPlainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatDate(_ isoString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        inputFormatter.timeZone = TimeZone(identifier: "UTC")
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = inputFormatter.date(from: isoString) else {
            return "Parse failed: \(isoString)"
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .medium
        outputFormatter.timeZone = TimeZone.current
        outputFormatter.locale = Locale.current

        let timeZoneName =
            TimeZone.current.localizedName(for: .shortStandard, locale: .current)
            ?? TimeZone.current.identifier
        return "\(outputFormatter.string(from: date)) (\(timeZoneName))"
    }
}
#endif
