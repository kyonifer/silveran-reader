import SwiftUI

struct TVSpeedPickerView: View {
    let viewModel: TVPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.75, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 5.0]

    var body: some View {
        NavigationStack {
            List(speeds, id: \.self) { speed in
                Button {
                    viewModel.setPlaybackRate(speed)
                    dismiss()
                } label: {
                    HStack {
                        Text(formatSpeed(speed))
                            .font(.headline)

                        Spacer()

                        if abs(speed - viewModel.playbackRate) < 0.01 {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Playback Speed")
        }
    }

    private func formatSpeed(_ speed: Double) -> String {
        if speed == 1.0 {
            return "Normal (1.0x)"
        }
        return String(format: "%.2gx", speed)
    }
}
