#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

enum PlaybackRatePolicy {
    static let minimumRate = kMinimumPlaybackSpeed
    static let maximumRate = kMaximumPlaybackSpeed
    static let sliderStep = PlaybackSpeedPolicy.sliderStep
    static let presetStep = PlaybackSpeedPolicy.presetStep
    static let presetRates = PlaybackSpeedPolicy.presetRates

    static func formattedCurrentRate(_ rate: Double) -> String {
        String(format: "%.2fx", rate)
    }

    static func formattedPresetRate(_ rate: Double) -> String {
        if rate == rate.rounded() {
            return String(format: "%.1fx", rate)
        }
        let formatted = String(format: "%.2f", rate)
        if formatted.hasSuffix("0") {
            return String(format: "%.1fx", rate)
        }
        return "\(formatted)x"
    }

    static func activeRole(
        isReaderSceneActive: Bool,
        isPlayerExpanded: Bool,
    ) -> PlaybackSpeedRole {
        isReaderSceneActive && !isPlayerExpanded ? .readaloud : .listening
    }
}

#endif
