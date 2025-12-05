import SwiftUI

#if os(macOS)
import AppKit
#endif

struct EbookPlayerSettings: View {
    @Bindable var settingsVM: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    let onDismiss: (() -> Void)?

    @State private var fontSizeInput: String = "20"
    @State private var showCustomColorPicker = false
    #if os(iOS)
    @State private var showBackgroundColorPicker = false
    @State private var showForegroundColorPicker = false
    @State private var showFontPicker = false
    #endif
    #if os(macOS)
    @State private var fontPanelResponder: FontPanelResponder? = nil
    #endif

    private var defaultHighlightColor: String {
        colorScheme == .dark ? "#333333" : "#CCCCCC"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            Text("Reader")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Slider(value: $settingsVM.fontSize, in: 8...60, step: 1)
                        .onChange(of: settingsVM.fontSize) { _, newValue in
                            fontSizeInput = String(Int(newValue))
                            Task { try? await settingsVM.save() }
                        }
                    TextField("Size", text: $fontSizeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            if let value = Double(fontSizeInput), value >= 8, value <= 60 {
                                settingsVM.fontSize = value
                                Task { try? await settingsVM.save() }
                            } else {
                                fontSizeInput = String(Int(settingsVM.fontSize))
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Font")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Font", selection: $settingsVM.fontFamily) {
                    Text("System Default").tag("System Default")
                    Text("Serif").tag("serif")
                    Text("Sans-Serif").tag("sans-serif")
                    Text("Monospace").tag("monospace")
                    if isCustomFont(settingsVM.fontFamily) {
                        Text(settingsVM.fontFamily).tag(settingsVM.fontFamily)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settingsVM.fontFamily) { _, _ in
                    Task { try? await settingsVM.save() }
                }

                #if os(macOS)
                Button("Choose Custom Font...") {
                    selectCustomFont()
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .font(.caption)
                #elseif os(iOS)
                Button("Choose Custom Font...") {
                    showFontPicker = true
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .font(.caption)
                .sheet(isPresented: $showFontPicker) {
                    FontPickerView { fontDescriptor in
                        let fontName = fontDescriptor.postscriptName
                        settingsVM.fontFamily = fontName
                        Task { try? await settingsVM.save() }
                    }
                }
                #endif
            }

            Toggle("Single Column", isOn: $settingsVM.singleColumnMode)
                .onChange(of: settingsVM.singleColumnMode) { _, _ in
                    Task { try? await settingsVM.save() }
                }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Highlight Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    highlightColorButton(
                        lightColor: "#AAAAAA",
                        darkColor: "#333333",
                        label: "Grey"
                    )
                    highlightColorButton(
                        lightColor: "#FFC857",
                        darkColor: "#B8860B",
                        label: "Yellow"
                    )
                    highlightColorButton(
                        lightColor: "#4DABF7",
                        darkColor: "#1C7ED6",
                        label: "Blue"
                    )
                    Button {
                        showCustomColorPicker = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(
                                        Color(
                                            hex: settingsVM.highlightColor ?? defaultHighlightColor
                                        ) ?? Color.gray
                                    )
                                    .frame(width: 28, height: 28)
                                Image(systemName: "eyedropper")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                            }
                            Text("Custom")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showCustomColorPicker) {
                        ColorPicker(
                            "Highlight Color",
                            selection: Binding(
                                get: { Color(hex: settingsVM.highlightColor ?? self.defaultHighlightColor) ?? .yellow },
                                set: {
                                    settingsVM.highlightColor =
                                        $0.hexString() ?? settingsVM.highlightColor
                                    Task { try? await settingsVM.save() }
                                }
                            )
                        )
                        .padding()
                    }
                }
            }

            #if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                Text("Background Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        settingsVM.backgroundColor = nil
                        Task { try? await settingsVM.save() }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(.clear)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                Image(systemName: "nosign")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                            }
                            Text("Default")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        showBackgroundColorPicker = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(
                                        Color(
                                            hex: settingsVM.backgroundColor ?? "#FFFFFF"
                                        ) ?? Color.gray
                                    )
                                    .frame(width: 28, height: 28)
                                Image(systemName: "eyedropper")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                            }
                            Text("Custom")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showBackgroundColorPicker) {
                        ColorPicker(
                            "Background Color",
                            selection: Binding(
                                get: {
                                    Color(hex: settingsVM.backgroundColor ?? "#FFFFFF") ?? .gray
                                },
                                set: {
                                    settingsVM.backgroundColor =
                                        $0.hexString() ?? settingsVM.backgroundColor
                                    Task { try? await settingsVM.save() }
                                }
                            )
                        )
                        .padding()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Text Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        settingsVM.foregroundColor = nil
                        Task { try? await settingsVM.save() }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(.clear)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                Image(systemName: "nosign")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                            }
                            Text("Default")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        showForegroundColorPicker = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(
                                        Color(
                                            hex: settingsVM.foregroundColor ?? "#000000"
                                        ) ?? Color.gray
                                    )
                                    .frame(width: 28, height: 28)
                                Image(systemName: "eyedropper")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                            }
                            Text("Custom")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showForegroundColorPicker) {
                        ColorPicker(
                            "Text Color",
                            selection: Binding(
                                get: {
                                    Color(hex: settingsVM.foregroundColor ?? "#000000") ?? .gray
                                },
                                set: {
                                    settingsVM.foregroundColor =
                                        $0.hexString() ?? settingsVM.foregroundColor
                                    Task { try? await settingsVM.save() }
                                }
                            )
                        )
                        .padding()
                    }
                }
            }
            #endif

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Margins (Left/Right): \(Int(settingsVM.marginLeftRight))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settingsVM.marginLeftRight, in: 0...30, step: 1)
                    .onChange(of: settingsVM.marginLeftRight) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Margins (Top/Bottom): \(Int(settingsVM.marginTopBottom))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settingsVM.marginTopBottom, in: 0...30, step: 1)
                    .onChange(of: settingsVM.marginTopBottom) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Word Spacing: \(String(format: "%.1f", settingsVM.wordSpacing))em")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settingsVM.wordSpacing, in: -0.5...2.0, step: 0.1)
                    .onChange(of: settingsVM.wordSpacing) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Letter Spacing: \(String(format: "%.2f", settingsVM.letterSpacing))em")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settingsVM.letterSpacing, in: -0.1...0.5, step: 0.01)
                    .onChange(of: settingsVM.letterSpacing) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
            }

            #if os(macOS)
            Divider()

            Text("Overlay Stats")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Overlay Stats", isOn: $settingsVM.enableReadingBar)
                    .font(.caption)
                    .onChange(of: settingsVM.enableReadingBar) { _, _ in
                        Task { try? await settingsVM.save() }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transparency: \(Int(settingsVM.overlayTransparency * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $settingsVM.overlayTransparency,
                        in: 0.1...1.0,
                        step: 0.01
                    )
                    .onChange(of: settingsVM.overlayTransparency) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
                }
                .disabled(!settingsVM.enableReadingBar)
                .opacity(settingsVM.enableReadingBar ? 1.0 : 0.5)

                Toggle("Show Player Controls", isOn: $settingsVM.showPlayerControls)
                    .font(.caption)
                    .disabled(!settingsVM.enableReadingBar)
                    .onChange(of: settingsVM.showPlayerControls) { _, _ in
                        Task { try? await settingsVM.save() }
                    }

                Toggle("Show Progress Bar", isOn: $settingsVM.showProgressBar)
                    .font(.caption)
                    .disabled(!settingsVM.enableReadingBar)
                    .onChange(of: settingsVM.showProgressBar) { _, _ in
                        Task { try? await settingsVM.save() }
                    }

                Toggle("Show Page Number in Chapter", isOn: $settingsVM.showPageNumber)
                    .font(.caption)
                    .disabled(!settingsVM.enableReadingBar)
                    .onChange(of: settingsVM.showPageNumber) { _, _ in
                        Task { try? await settingsVM.save() }
                    }

                Toggle("Show Book Progress (%)", isOn: $settingsVM.showProgress)
                    .font(.caption)
                    .disabled(!settingsVM.enableReadingBar)
                    .onChange(of: settingsVM.showProgress) { _, _ in
                        Task { try? await settingsVM.save() }
                    }

                Toggle(
                    "Show Time Remaining in Chapter",
                    isOn: $settingsVM.showTimeRemainingInChapter
                )
                .font(.caption)
                .disabled(!settingsVM.enableReadingBar)
                .onChange(of: settingsVM.showTimeRemainingInChapter) { _, _ in
                    Task { try? await settingsVM.save() }
                }

                Toggle("Show Time Remaining in Book", isOn: $settingsVM.showTimeRemainingInBook)
                    .font(.caption)
                    .disabled(!settingsVM.enableReadingBar)
                    .onChange(of: settingsVM.showTimeRemainingInBook) { _, _ in
                        Task { try? await settingsVM.save() }
                    }
            }
            #endif

            #if os(macOS)
            Divider()

            Button {
                onDismiss?()
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                    Text("More Settings...")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            #endif
        }
        .onAppear {
            fontSizeInput = String(Int(settingsVM.fontSize))
        }
    }

    private func resetToDefaults() {
        settingsVM.fontSize = 24
        settingsVM.fontFamily = "System Default"
        settingsVM.marginLeftRight = 8
        settingsVM.marginTopBottom = 8
        settingsVM.wordSpacing = 0
        settingsVM.letterSpacing = 0
        settingsVM.highlightColor = colorScheme == .dark ? "#333333" : "#CCCCCC"
        #if os(iOS)
        if colorScheme == .dark {
            settingsVM.backgroundColor = kDefaultBackgroundColorIOSDark
            settingsVM.foregroundColor = kDefaultForegroundColorIOSDark
        } else {
            settingsVM.backgroundColor = kDefaultBackgroundColorIOSLight
            settingsVM.foregroundColor = kDefaultForegroundColorIOSLight
        }
        #else
        settingsVM.backgroundColor = nil
        settingsVM.foregroundColor = nil
        #endif
        settingsVM.enableReadingBar = true
        settingsVM.showProgressBar = false
        settingsVM.showProgress = true
        settingsVM.showTimeRemainingInBook = true
        settingsVM.showTimeRemainingInChapter = true
        settingsVM.showPageNumber = true
        settingsVM.overlayTransparency = 0.8
        #if os(iOS)
        settingsVM.showPlayerControls = true
        settingsVM.singleColumnMode = true
        #else
        settingsVM.showPlayerControls = false
        settingsVM.singleColumnMode = false
        #endif

        Task { try? await settingsVM.save() }
    }

    private func isCustomFont(_ fontFamily: String) -> Bool {
        !["System Default", "serif", "sans-serif", "monospace"].contains(fontFamily)
    }

    private func highlightColorButton(lightColor: String, darkColor: String, label: String)
        -> some View
    {
        let colorToUse = colorScheme == .dark ? darkColor : lightColor
        let isSelected =
            settingsVM.highlightColor == lightColor || settingsVM.highlightColor == darkColor

        return Button {
            settingsVM.highlightColor = colorToUse
            Task { try? await settingsVM.save() }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: colorToUse) ?? .gray)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isSelected ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                    )
                Text(label)
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
    }

    #if os(macOS)
    @MainActor
    private func selectCustomFont() {
        if fontPanelResponder == nil {
            fontPanelResponder = FontPanelResponder()
        }

        guard let responder = fontPanelResponder else { return }

        responder.onFontChanged = { fontName in
            settingsVM.fontFamily = fontName
            Task { try? await settingsVM.save() }
        }

        let fontManager = NSFontManager.shared
        fontManager.target = responder
        fontManager.action = #selector(FontPanelResponder.changeFont(_:))

        let fontPanel = NSFontPanel.shared
        let currentFont =
            NSFont(name: settingsVM.fontFamily, size: settingsVM.fontSize)
            ?? NSFont.systemFont(ofSize: settingsVM.fontSize)
        fontPanel.setPanelFont(currentFont, isMultiple: false)
        fontPanel.orderFront(nil)
    }
    #endif
}

#if os(macOS)
@MainActor
private class FontPanelResponder: NSObject {
    var onFontChanged: ((String) -> Void)?

    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let selectedFont = fontManager.convert(NSFont.systemFont(ofSize: 16))
        onFontChanged?(selectedFont.fontName)
    }
}
#endif

#if os(iOS)
import UIKit

struct FontPickerView: UIViewControllerRepresentable {
    let onFontPicked: (UIFontDescriptor) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = true
        let picker = UIFontPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFontPicked: onFontPicked)
    }

    class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let onFontPicked: (UIFontDescriptor) -> Void

        init(onFontPicked: @escaping (UIFontDescriptor) -> Void) {
            self.onFontPicked = onFontPicked
        }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let descriptor = viewController.selectedFontDescriptor {
                onFontPicked(descriptor)
            }
        }
    }
}
#endif
