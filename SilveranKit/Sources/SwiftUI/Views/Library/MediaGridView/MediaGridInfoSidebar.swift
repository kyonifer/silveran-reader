import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct MediaGridInfoSidebar: View {
    let item: BookMetadata
    let mediaKind: MediaKind?
    let onClose: () -> Void
    let onReadNow: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var animatedProgress: Double = 0

    init(
        item: BookMetadata,
        mediaKind: MediaKind? = nil,
        onClose: @escaping () -> Void,
        onReadNow: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.mediaKind = mediaKind
        self.onClose = onClose
        self.onReadNow = onReadNow
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.vertical, 12)
            ScrollView {
                content
            }
        }
        .background(.thinMaterial)
        .onAppear(perform: prepareForDisplay)
        .onChange(of: item.id) { _, _ in
            prepareForDisplay()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
                Text(item.authors?.first?.name ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressSection
            MediaGridDownloadSection(item: item)
            descriptionSection
            lastReadDateSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reading Progress")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Text(progressLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: animatedProgress, total: 1)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.45), value: animatedProgress)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = item.description {
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(htmlToAttributedString(description))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var lastReadDateSection: some View {
        if let positionUpdatedAt = item.position?.updatedAt {
            VStack(alignment: .leading, spacing: 6) {
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

    private var progressLabel: String {
        "\(Int((item.progress * 100).rounded()))%"
    }

    private func prepareForDisplay() {
        animatedProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) {
                animatedProgress = item.progress
            }
        }
    }

    private func htmlToAttributedString(_ html: String) -> AttributedString {
        #if canImport(AppKit) || canImport(UIKit)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #else
        let font = UIFont.systemFont(ofSize: UIFont.systemFontSize)
        #endif

        let wrappedHTML = """
            <html>
            <head>
            <style>
            body {
                font-family: -apple-system;
                font-size: \(font.pointSize)px;
            }
            </style>
            </head>
            <body>\(html)</body>
            </html>
            """

        if let data = wrappedHTML.data(using: .utf8),
            let nsAttributedString = try? NSAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )
        {
            return AttributedString(nsAttributedString)
        }
        #endif

        return AttributedString(html)
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

        let timeZoneName = TimeZone.current.localizedName(for: .shortStandard, locale: .current) ?? TimeZone.current.identifier
        return "\(outputFormatter.string(from: date)) (\(timeZoneName))"
    }
}
