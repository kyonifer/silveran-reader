import DefaultBackend
import Foundation
import SilveranKit
import SwiftCrossUI

@main
struct SilveranReaderApp: App {
    var body: some Scene {
        WindowGroup("Silveran Reader") {
            PlaceholderView()
        }
        .defaultSize(width: 1180, height: 760)
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Silveran Reader")
                .font(.system(size: 24, weight: .semibold))
            Text("Linux UI is coming soon.")
                .foregroundColor(Color(red: 0.64, green: 0.68, blue: 0.74))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
