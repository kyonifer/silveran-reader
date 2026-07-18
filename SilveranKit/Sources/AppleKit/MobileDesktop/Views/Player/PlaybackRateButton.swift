#if os(iOS) || os(macOS)
import SwiftUI

public struct PlaybackRateButton: View {
    private let playbackSpeeds: PlaybackSpeedControls
    private let backgroundColor: Color
    private let foregroundColor: Color
    private let transparency: Double
    private let showLabel: Bool
    private let buttonSize: CGFloat
    private let showBackground: Bool
    private let compactLabel: Bool
    private let iconFont: Font

    @ScaledMetric(relativeTo: .caption) private var presetButtonWidth: CGFloat = 60

    @State private var showSpeedPicker = false
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSpeedSheetDetent: PresentationDetent = .custom(
        CompactPlaybackSpeedDetent.self
    )
    #endif

    public init(
        playbackSpeeds: PlaybackSpeedControls,
        backgroundColor: Color = Color.secondary,
        foregroundColor: Color = Color.primary,
        transparency: Double = 1.0,
        showLabel: Bool = true,
        buttonSize: CGFloat = 38,
        showBackground: Bool = true,
        compactLabel: Bool = false,
        iconFont: Font = .callout.weight(.semibold),
    ) {
        self.playbackSpeeds = playbackSpeeds
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.transparency = transparency
        self.showLabel = showLabel
        self.buttonSize = buttonSize
        self.showBackground = showBackground
        self.compactLabel = compactLabel
        self.iconFont = iconFont
        #if os(iOS)
        if !playbackSpeeds.isDual {
            _selectedSpeedSheetDetent = State(
                initialValue: .custom(CompactSinglePlaybackSpeedDetent.self)
            )
        }
        #endif
    }

    public init(
        currentRate: Double,
        rate: Binding<Double>,
        backgroundColor: Color = Color.secondary,
        foregroundColor: Color = Color.primary,
        transparency: Double = 1.0,
        showLabel: Bool = true,
        buttonSize: CGFloat = 38,
        showBackground: Bool = true,
        compactLabel: Bool = false,
        iconFont: Font = .callout.weight(.semibold),
    ) {
        self.init(
            playbackSpeeds: .single(currentRate: currentRate, rate: rate),
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            transparency: transparency,
            showLabel: showLabel,
            buttonSize: buttonSize,
            showBackground: showBackground,
            compactLabel: compactLabel,
            iconFont: iconFont,
        )
    }

    public var body: some View {
        VStack(spacing: compactLabel ? 0 : 6) {
            #if os(iOS)
            speedPickerButton
                .sheet(isPresented: $showSpeedPicker) {
                    speedSheet
                }
            #else
            speedPickerButton
                .popover(isPresented: $showSpeedPicker) {
                    speedPickerContent
                        .frame(width: playbackSpeeds.isDual ? 440 : 340)
                        .padding()
                }
            #endif

            if showLabel && !compactLabel {
                Text(playbackRateDescription)
                    .font(.footnote)
                    .foregroundStyle(foregroundColor.opacity(0.7 * transparency))
            }
        }
        .overlay(alignment: .bottom) {
            if showLabel && compactLabel {
                Text(playbackRateDescription)
                    .font(.caption2)
                    .foregroundStyle(foregroundColor.opacity(0.7 * transparency))
                    .offset(y: 9)
            }
        }
    }

    private var speedPickerButton: some View {
        Button(action: presentSpeedPicker) {
            Image(systemName: "speedometer")
                .font(iconFont)
                .foregroundStyle(foregroundColor.opacity(transparency))
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    if showBackground {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(backgroundColor.opacity(0.12 * transparency))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speedPickerTitle)
    }

    private var speedPickerContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch playbackSpeeds {
                case .single(_, let rate):
                    speedControl(title: "Playback Speed", value: rate)
                case .dual(_, let listeningRate, let readaloudRate):
                    speedControl(title: "Listening Speed", value: listeningRate)
                    speedControl(title: "Read-aloud Speed", value: readaloudRate)
            }
        }
    }

    private var presetGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: presetButtonWidth,
                    maximum: presetButtonWidth,
                ),
                spacing: 8,
            )
        ]
    }

    private func speedControl(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(PlaybackRatePolicy.formattedCurrentRate(value.wrappedValue))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            Slider(
                value: value,
                in: PlaybackRatePolicy.minimumRate...PlaybackRatePolicy.maximumRate,
                step: PlaybackRatePolicy.sliderStep,
            )

            LazyVGrid(
                columns: presetGridColumns,
                alignment: .leading,
                spacing: 8,
            ) {
                ForEach(PlaybackRatePolicy.presetRates, id: \.self) { rate in
                    Button {
                        value.wrappedValue = rate
                    } label: {
                        Text(PlaybackRatePolicy.formattedPresetRate(rate))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(iOS)
    private var speedSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(speedPickerTitle)
                    .font(.title2.weight(.bold))

                Spacer()

                Button("Done") {
                    showSpeedPicker = false
                }
                .font(.body.weight(.semibold))
            }

            ViewThatFits(in: .vertical) {
                speedPickerContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    speedPickerContent
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents(
            speedSheetDetents,
            selection: $selectedSpeedSheetDetent,
        )
        .presentationDragIndicator(.visible)
        .onChange(of: dynamicTypeSize) { _, newSize in
            selectedSpeedSheetDetent = preferredSpeedSheetDetent(for: newSize)
        }
    }
    #endif

    private func presentSpeedPicker() {
        #if os(iOS)
        selectedSpeedSheetDetent = preferredSpeedSheetDetent(for: dynamicTypeSize)
        #endif
        showSpeedPicker = true
    }

    #if os(iOS)
    private func preferredSpeedSheetDetent(for typeSize: DynamicTypeSize) -> PresentationDetent {
        if typeSize > .large {
            return .large
        }
        return playbackSpeeds.isDual
            ? .custom(CompactPlaybackSpeedDetent.self)
            : .custom(CompactSinglePlaybackSpeedDetent.self)
    }

    private var speedSheetDetents: Set<PresentationDetent> {
        [preferredSpeedSheetDetent(for: .large), .large]
    }
    #endif

    private var speedPickerTitle: String {
        playbackSpeeds.isDual ? "Playback Speeds" : "Playback Speed"
    }

    private var playbackRateDescription: String {
        PlaybackRatePolicy.formattedCurrentRate(playbackSpeeds.currentRate)
    }
}

#if os(iOS)
private struct CompactPlaybackSpeedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue * 0.7, 500)
    }
}

private struct CompactSinglePlaybackSpeedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue * 0.55, 360)
    }
}
#endif

#endif
