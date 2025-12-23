import SwiftUI

struct PlaceholderDetailView: View {
    var title: String
    var body: some View {
        VStack(spacing: 12) {
            Text("Your Library Is Empty!").font(.title)
            Text("Use the Media Sources tabs on the left to add media to your library.")
                .foregroundStyle(
                    .secondary
                )
            Text("(\(title))").font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
