import SwiftUI

public struct PlaybackRateButton: View {
    private let currentRate: Double
    private let onRateChange: (Double) -> Void
    private let backgroundColor: Color
    private let foregroundColor: Color
    private let transparency: Double
    private let showLabel: Bool
    private let buttonSize: CGFloat
    private let showBackground: Bool
    private let compactLabel: Bool
    private let iconFont: Font

    @State private var showCustomInput = false
    @State private var customPlaybackRate: String = ""

    public init(
        currentRate: Double,
        onRateChange: @escaping (Double) -> Void,
        backgroundColor: Color = Color.secondary,
        foregroundColor: Color = Color.primary,
        transparency: Double = 1.0,
        showLabel: Bool = true,
        buttonSize: CGFloat = 38,
        showBackground: Bool = true,
        compactLabel: Bool = false,
        iconFont: Font = .callout.weight(.semibold)
    ) {
        self.currentRate = currentRate
        self.onRateChange = onRateChange
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.transparency = transparency
        self.showLabel = showLabel
        self.buttonSize = buttonSize
        self.showBackground = showBackground
        self.compactLabel = compactLabel
        self.iconFont = iconFont
    }

    public var body: some View {
        VStack(spacing: compactLabel ? 0 : 6) {
            #if os(iOS)
            Button(action: { showCustomInput = true }) {
                Image(systemName: "speedometer")
                    .font(iconFont)
                    .foregroundStyle(foregroundColor.opacity(transparency))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Group {
                            if showBackground {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(backgroundColor.opacity(0.12 * transparency))
                            }
                        }
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showCustomInput) {
                speedSheet
            }
            #else
            Menu {
                ForEach([0.75, 1.0, 1.1, 1.2, 1.25, 1.3], id: \.self) { rate in
                    Button(action: {
                        onRateChange(rate)
                    }) {
                        HStack {
                            Text(String(format: "%.2fx", rate))
                            if abs(currentRate - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button("Custom Speed...") {
                    customPlaybackRate = String(format: "%.1f", currentRate)
                    showCustomInput = true
                }
            } label: {
                Image(systemName: "speedometer")
                    .font(iconFont)
                    .foregroundStyle(foregroundColor.opacity(transparency))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Group {
                            if showBackground {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(backgroundColor.opacity(0.12 * transparency))
                            }
                        }
                    )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .alert("Custom Playback Speed", isPresented: $showCustomInput) {
                TextField("1.0", text: $customPlaybackRate)
                    .frame(width: 100)
                Button("Cancel", role: .cancel) {
                    customPlaybackRate = ""
                }
                Button("Set") {
                    if let rate = Double(customPlaybackRate), rate >= 0.5, rate <= 10.0 {
                        onRateChange(rate)
                        customPlaybackRate = ""
                    }
                }
            } message: {
                Text("Enter a playback speed between 0.5x and 10.0x")
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

    #if os(iOS)
    private var speedSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach([0.75, 1.0, 1.1, 1.2, 1.25, 1.3], id: \.self) { rate in
                        Button(action: {
                            onRateChange(rate)
                            showCustomInput = false
                        }) {
                            HStack {
                                Text(String(format: "%.2fx", rate))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if abs(currentRate - rate) < 0.01 {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Preset Speeds")
                }

                Section {
                    HStack {
                        TextField("1.0", text: $customPlaybackRate)
                            .keyboardType(.decimalPad)
                        Button("Set") {
                            if let rate = Double(customPlaybackRate), rate >= 0.5, rate <= 10.0 {
                                onRateChange(rate)
                                customPlaybackRate = ""
                                showCustomInput = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            Double(customPlaybackRate) == nil
                                || Double(customPlaybackRate).map { $0 < 0.5 || $0 > 10.0 } ?? true
                        )
                    }
                } header: {
                    Text("Custom Speed")
                } footer: {
                    Text("Enter a playback speed between 0.5x and 10.0x")
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        customPlaybackRate = ""
                        showCustomInput = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    #endif

    private var playbackRateDescription: String {
        let formatted = String(format: "%.2fx", currentRate)
        if formatted.hasSuffix("0x") {
            return String(format: "%.1fx", currentRate)
        }
        return formatted
    }
}
