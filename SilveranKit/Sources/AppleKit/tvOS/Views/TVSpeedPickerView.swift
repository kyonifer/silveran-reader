#if os(tvOS)
import SilveranKit
import SwiftUI

struct TVSpeedPickerView: View {
    let viewModel: TVPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedIndex: Int?

    private let speeds = PlaybackSpeedPolicy.quickPresetRates

    private var currentSpeedIndex: Int? {
        speeds.firstIndex { abs($0 - viewModel.playbackRate) < 0.01 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(speeds.enumerated()), id: \.offset) { index, speed in
                        Button {
                            viewModel.setPlaybackRate(speed)
                            Task {
                                try? await SettingsActor.shared.updateConfig(
                                    defaultPlaybackSpeed: speed
                                )
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
                            .padding()
                        }
                        .buttonStyle(.plain)
                        .focused($focusedIndex, equals: index)
                    }
                }
            }
            .defaultFocus($focusedIndex, currentSpeedIndex)
            .navigationTitle("Playback Speed")
        }
    }

}
#endif
