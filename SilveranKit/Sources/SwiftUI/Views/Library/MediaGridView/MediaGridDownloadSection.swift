import SwiftUI

struct MediaGridDownloadSection: View {
    let item: BookMetadata

    var body: some View {
        let options = MediaGridViewUtilities.mediaDownloadOptions(for: item)
        Group {
            if options.isEmpty {
                EmptyView()
            } else {
                content(with: options)
            }
        }
    }

    @ViewBuilder
    private func content(with options: [MediaDownloadOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Media")
                .font(.callout)
                .fontWeight(.medium)

            MediaDownloadOptionsList(item: item, options: options)
        }
    }
}
