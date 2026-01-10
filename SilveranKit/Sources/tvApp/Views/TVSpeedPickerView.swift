import SilveranKitCommon
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
                    Task {
                        try? await SettingsActor.shared.updateConfig(defaultPlaybackSpeed: speed)
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(formatSpeedPickerLabel(speed, includeNormalLabel: true))
                            .font(.headline)

                        Spacer()

                        if abs(speed - viewModel.playbackRate) < 0.01 {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                // Workaround: default button style causes blurred text on focus in tvOS Lists
                .buttonStyle(.plain)
            }
            .navigationTitle("Playback Speed")
        }
    }

}
