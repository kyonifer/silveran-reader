import SwiftUI

struct TVSubtitleOverlay: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title2)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.7))
            }
            .frame(maxWidth: 1200)
            .animation(.easeInOut(duration: 0.2), value: text)
    }
}
