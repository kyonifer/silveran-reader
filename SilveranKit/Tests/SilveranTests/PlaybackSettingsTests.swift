import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

@Test func playbackSpeedsRoundTripIndependently() throws {
    let original = SilveranGlobalConfig(
        playback: .init(
            defaultPlaybackSpeed: 1.25,
            readaloudPlaybackSpeed: 2.5,
        )
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SilveranGlobalConfig.self, from: encoded)

    #expect(decoded.playback.defaultPlaybackSpeed == 1.25)
    #expect(decoded.playback.readaloudPlaybackSpeed == 2.5)
}

@Test func playbackSpeedUpdatesPreserveTheSupportedRangeAndCoupling() {
    var playback = SilveranGlobalConfig.Playback(
        defaultPlaybackSpeed: 5.0,
        readaloudPlaybackSpeed: 10.0,
    )

    #expect(playback.defaultPlaybackSpeed == kMaximumPlaybackSpeed)
    #expect(playback.readaloudPlaybackSpeed == kMaximumPlaybackSpeed)

    playback.updateReadaloudPlaybackSpeed(0.5)
    #expect(playback.defaultPlaybackSpeed == kMinimumPlaybackSpeed)
    #expect(playback.readaloudPlaybackSpeed == kMinimumPlaybackSpeed)

    playback.updateDefaultPlaybackSpeed(5.0)
    #expect(playback.defaultPlaybackSpeed == kMaximumPlaybackSpeed)
    #expect(playback.readaloudPlaybackSpeed == kMaximumPlaybackSpeed)
}

@Test func orderedPlaybackSpeedUpdatesApplyToTheLatestState() {
    var playback = SilveranGlobalConfig.Playback(
        defaultPlaybackSpeed: 1.0,
        readaloudPlaybackSpeed: 2.0,
    )

    playback.updatePlaybackSpeed(2.5, for: .listening)
    playback.updatePlaybackSpeed(2.25, for: .readaloud)

    #expect(playback.defaultPlaybackSpeed == 2.25)
    #expect(playback.readaloudPlaybackSpeed == 2.25)
}

@Test func playbackSpeedPresetsCoverRequestedRangeInQuarterSteps() {
    #expect(PlaybackSpeedPolicy.sliderStep == 0.05)
    #expect(PlaybackSpeedPolicy.presetStep == 0.25)
    #expect(PlaybackSpeedPolicy.presetRates.first == 0.75)
    #expect(PlaybackSpeedPolicy.presetRates.last == 4.0)
    #expect(PlaybackSpeedPolicy.presetRates.count == 14)
    #expect(PlaybackRatePolicy.presetRates == PlaybackSpeedPolicy.presetRates)
    #expect(
        zip(
            PlaybackSpeedPolicy.presetRates.dropFirst(),
            PlaybackSpeedPolicy.presetRates,
        ).allSatisfy { next, previous in
            abs(next - previous - 0.25) < 0.001
        }
    )
}

@Test func currentPlaybackRateAlwaysUsesTwoDecimalPlaces() {
    #expect(PlaybackRatePolicy.formattedCurrentRate(2.0) == "2.00x")
    #expect(PlaybackRatePolicy.formattedCurrentRate(2.05) == "2.05x")
    #expect(PlaybackRatePolicy.formattedPresetRate(2.0) == "2.0x")
}

@Test func compactPlatformSpeedPresetsShareTheSupportedRange() {
    #expect(PlaybackSpeedPolicy.quickPresetRates.first == kMinimumPlaybackSpeed)
    #expect(PlaybackSpeedPolicy.quickPresetRates.last == kMaximumPlaybackSpeed)
    #expect(
        PlaybackSpeedPolicy.quickPresetRates.allSatisfy { rate in
            (kMinimumPlaybackSpeed...kMaximumPlaybackSpeed).contains(rate)
        }
    )
}

@Test(
    arguments: [
        (isReaderActive: true, isExpanded: false, expected: PlaybackSpeedRole.readaloud),
        (isReaderActive: true, isExpanded: true, expected: PlaybackSpeedRole.listening),
        (isReaderActive: false, isExpanded: false, expected: PlaybackSpeedRole.listening),
        (isReaderActive: false, isExpanded: true, expected: PlaybackSpeedRole.listening),
    ]
)
func playbackRoleSelectionUsesReadaloudOnlyInUnexpandedActiveReader(
    context: (isReaderActive: Bool, isExpanded: Bool, expected: PlaybackSpeedRole)
) {
    let role = PlaybackRatePolicy.activeRole(
        isReaderSceneActive: context.isReaderActive,
        isPlayerExpanded: context.isExpanded,
    )

    #expect(role == context.expected)
}

@Test(
    arguments: [
        (listening: 2.0, readaloud: 1.5, expected: 2.0),
        (listening: 1.5, readaloud: 2.0, expected: 2.0),
        (listening: 2.0, readaloud: 2.0, expected: 2.0),
    ]
)
func raisingListeningSpeedOnlyRaisesLowerReadaloudSpeed(
    rates: (listening: Double, readaloud: Double, expected: Double)
) {
    var playback = SilveranGlobalConfig.Playback(
        defaultPlaybackSpeed: 1.0,
        readaloudPlaybackSpeed: rates.readaloud,
    )
    playback.updateDefaultPlaybackSpeed(rates.listening)

    #expect(playback.defaultPlaybackSpeed == rates.listening)
    #expect(playback.readaloudPlaybackSpeed == rates.expected)
}

@Test(
    arguments: [
        (listening: 2.0, readaloud: 1.5, expected: 1.5),
        (listening: 1.5, readaloud: 2.0, expected: 1.5),
        (listening: 2.0, readaloud: 2.0, expected: 2.0),
    ]
)
func loweringReadaloudSpeedOnlyLowersHigherListeningSpeed(
    rates: (listening: Double, readaloud: Double, expected: Double)
) {
    var playback = SilveranGlobalConfig.Playback(
        defaultPlaybackSpeed: rates.listening,
        readaloudPlaybackSpeed: 2.5,
    )
    playback.updateReadaloudPlaybackSpeed(rates.readaloud)

    #expect(playback.defaultPlaybackSpeed == rates.expected)
    #expect(playback.readaloudPlaybackSpeed == rates.readaloud)
}
