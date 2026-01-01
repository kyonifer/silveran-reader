import SwiftUI
import UniformTypeIdentifiers

struct EbookPlayerSettings: View {
    @Bindable var settingsVM: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    let onDismiss: (() -> Void)?

    @State private var fontSizeInput: String = "20"
    #if os(iOS)
    @State private var customFamilies: [CustomFontFamily] = []
    @State private var showFontManager = false
    #endif

    private var defaultHighlightColor: String {
        colorScheme == .dark ? "#333333" : "#CCCCCC"
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                resetToDefaults()
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Slider(value: $settingsVM.fontSize, in: 8...60, step: 1)
                        .onChange(of: settingsVM.fontSize) { _, newValue in
                            fontSizeInput = String(Int(newValue))
                            settingsVM.save()
                        }
                    TextField("Size", text: $fontSizeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            if let val = Double(fontSizeInput), val >= 8, val <= 60 {
                                settingsVM.fontSize = val
                                settingsVM.save()
                            } else {
                                fontSizeInput = String(Int(settingsVM.fontSize))
                            }
                        }
                }
            }

            Divider()

            labeledSlider(
                label: "Margins (Left/Right)",
                value: $settingsVM.marginLeftRight,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" }
            )

            labeledSlider(
                label: "Margins (Top/Bottom)",
                value: $settingsVM.marginTopBottom,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" }
            )

            Divider()

            Button {
                onDismiss?()
                SettingsTabRequest.shared.requestReaderSettings()
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                    Text("More Settings...")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .onAppear {
            fontSizeInput = String(Int(settingsVM.fontSize))
        }
    }
    #endif

    #if os(iOS)
    private var iOSBody: some View {
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
                            settingsVM.save()
                        }
                    TextField("Size", text: $fontSizeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            if let val = Double(fontSizeInput), val >= 8, val <= 60 {
                                settingsVM.fontSize = val
                                settingsVM.save()
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

                    if !customFamilies.isEmpty {
                        Divider()
                        ForEach(customFamilies) { family in
                            Text(family.name).tag(family.name)
                        }
                    }

                    if isCustomFont(settingsVM.fontFamily) && !customFamilies.contains(where: { $0.name == settingsVM.fontFamily }) {
                        Text(settingsVM.fontFamily).tag(settingsVM.fontFamily)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settingsVM.fontFamily) { _, _ in
                    settingsVM.save()
                }

                Button("Manage Fonts...") {
                    showFontManager = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.caption)
                .sheet(isPresented: $showFontManager) {
                    IOSFontManagerView(
                        customFamilies: $customFamilies,
                        selectedFont: $settingsVM.fontFamily,
                        onSave: { settingsVM.save() }
                    )
                }
            }

            labeledSlider(
                label: "Readaloud Highlight Height",
                value: $settingsVM.highlightThickness,
                range: 0.6...4.0,
                step: 0.05,
                formatter: { String(format: "%.2fx", $0) }
            )

            Toggle("Single Column", isOn: $settingsVM.singleColumnMode)
                .onChange(of: settingsVM.singleColumnMode) { _, _ in
                    settingsVM.save()
                }

            Toggle("Margin Tap to Turn Pages", isOn: $settingsVM.enableMarginClickNavigation)
                .onChange(of: settingsVM.enableMarginClickNavigation) { _, _ in
                    settingsVM.save()
                }

            labeledSlider(
                label: "Line Spacing",
                value: $settingsVM.lineSpacing,
                range: 1.0...2.5,
                step: 0.1,
                formatter: { String(format: "%.1f", $0) }
            )

            Divider()

            labeledSlider(
                label: "Margins (Left/Right)",
                value: $settingsVM.marginLeftRight,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" }
            )

            labeledSlider(
                label: "Margins (Top/Bottom)",
                value: $settingsVM.marginTopBottom,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" }
            )

            Divider()

            labeledSlider(
                label: "Word Spacing",
                value: $settingsVM.wordSpacing,
                range: -0.5...2.0,
                step: 0.1,
                formatter: { String(format: "%.1fem", $0) }
            )

            labeledSlider(
                label: "Letter Spacing",
                value: $settingsVM.letterSpacing,
                range: -0.1...0.5,
                step: 0.01,
                formatter: { String(format: "%.2fem", $0) }
            )

            Divider()

            Text("Appearance")
                .font(.headline)
                .foregroundStyle(.primary)

            iOSColorControl(
                label: "Read Aloud Highlight",
                hex: $settingsVM.highlightColor,
                defaultHex: defaultHighlightColor
            )

            iOSColorControl(
                label: "Background Color",
                hex: $settingsVM.backgroundColor,
                defaultHex: nil
            )

            iOSColorControl(
                label: "Text Color",
                hex: $settingsVM.foregroundColor,
                defaultHex: nil
            )

            Divider()

            Text("Highlight Colors")
                .font(.headline)
                .foregroundStyle(.primary)

            iOSUserHighlightColorControl(
                label: "Highlight #1 (Yellow)",
                hex: $settingsVM.userHighlightColor1,
                defaultHex: "#B5B83E"
            )

            iOSUserHighlightColorControl(
                label: "Highlight #2 (Blue)",
                hex: $settingsVM.userHighlightColor2,
                defaultHex: "#4E90C7"
            )

            iOSUserHighlightColorControl(
                label: "Highlight #3 (Green)",
                hex: $settingsVM.userHighlightColor3,
                defaultHex: "#198744"
            )

            iOSUserHighlightColorControl(
                label: "Highlight #4 (Pink)",
                hex: $settingsVM.userHighlightColor4,
                defaultHex: "#E25EA3"
            )

            iOSUserHighlightColorControl(
                label: "Highlight #5 (Orange)",
                hex: $settingsVM.userHighlightColor5,
                defaultHex: "#CE8C4A"
            )

            iOSUserHighlightColorControl(
                label: "Highlight #6 (Purple)",
                hex: $settingsVM.userHighlightColor6,
                defaultHex: "#B366FF"
            )
        }
        .onAppear {
            fontSizeInput = String(Int(settingsVM.fontSize))
            Task {
                await loadCustomFonts()
            }
        }
    }

    private func loadCustomFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    @ViewBuilder
    private func iOSColorControl(label: String, hex: Binding<String?>, defaultHex: String?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            IOSAppearanceColorControl(
                hex: hex,
                defaultHex: defaultHex,
                onSave: { settingsVM.save() }
            )
        }
    }

    @ViewBuilder
    private func iOSUserHighlightColorControl(
        label: String,
        hex: Binding<String>,
        defaultHex: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            IOSUserHighlightColorControl(
                hex: hex,
                defaultHex: defaultHex,
                onSave: { settingsVM.save() }
            )
        }
    }
    #endif

    @ViewBuilder
    private func labeledSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(formatter(value.wrappedValue))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { _, _ in
                    settingsVM.save()
                }
        }
    }

    private func resetToDefaults() {
        settingsVM.fontSize = 24
        settingsVM.fontFamily = "System Default"
        settingsVM.lineSpacing = 1.4
        #if os(iOS)
        settingsVM.marginLeftRight = 2
        #else
        settingsVM.marginLeftRight = 5
        #endif
        settingsVM.marginTopBottom = 8
        settingsVM.wordSpacing = 0
        settingsVM.letterSpacing = 0
        settingsVM.highlightColor = nil
        settingsVM.highlightThickness = 1.0
        settingsVM.backgroundColor = nil
        settingsVM.foregroundColor = nil
        settingsVM.enableMarginClickNavigation = true
        settingsVM.enableReadingBar = true
        settingsVM.showProgressBar = false
        settingsVM.showProgress = true
        settingsVM.showTimeRemainingInBook = true
        settingsVM.showTimeRemainingInChapter = true
        settingsVM.showPageNumber = true
        settingsVM.overlayTransparency = 0.8
        settingsVM.singleColumnMode = true
        #if os(iOS)
        settingsVM.showPlayerControls = true
        #else
        settingsVM.showPlayerControls = false
        #endif
        settingsVM.lockViewToAudio = true

        settingsVM.save()
    }

    private func isCustomFont(_ fontFamily: String) -> Bool {
        !["System Default", "serif", "sans-serif", "monospace"].contains(fontFamily)
    }
}

#if os(iOS)
private struct IOSFontManagerView: View {
    @Binding var customFamilies: [CustomFontFamily]
    @Binding var selectedFont: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFontImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFontImporter = true
                    } label: {
                        Label("Import Font", systemImage: "plus.circle")
                    }
                    .fileImporter(
                        isPresented: $showFontImporter,
                        allowedContentTypes: [
                            UTType(filenameExtension: "ttf") ?? .data,
                            UTType(filenameExtension: "otf") ?? .data,
                            UTType.font
                        ],
                        allowsMultipleSelection: true
                    ) { result in
                        Task {
                            switch result {
                            case .success(let urls):
                                for url in urls {
                                    try? await CustomFontsActor.shared.importFont(from: url)
                                }
                                await refreshFonts()
                            case .failure:
                                break
                            }
                        }
                    }
                }

                Section("Custom Fonts") {
                    if customFamilies.isEmpty {
                        Text("No custom fonts imported")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customFamilies) { family in
                            DisclosureGroup {
                                ForEach(family.variants) { variant in
                                    HStack {
                                        Text(variant.styleDescription)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            deleteVariant(variant, from: family)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(family.name)
                                        Text("\(family.variants.count) variant\(family.variants.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedFont == family.name {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteFamily(family)
                                } label: {
                                    Label("Delete All", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await refreshFonts()
        }
    }

    private func refreshFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    private func deleteFamily(_ family: CustomFontFamily) {
        Task {
            if selectedFont == family.name {
                selectedFont = "System Default"
                onSave()
            }
            try? await CustomFontsActor.shared.deleteFamily(family)
            await MainActor.run {
                customFamilies.removeAll { $0.id == family.id }
            }
        }
    }

    private func deleteVariant(_ variant: CustomFontVariant, from family: CustomFontFamily) {
        Task {
            try? await CustomFontsActor.shared.deleteVariant(variant)
            await MainActor.run {
                if let familyIndex = customFamilies.firstIndex(where: { $0.id == family.id }) {
                    customFamilies[familyIndex].variants.removeAll { $0.id == variant.id }
                    if customFamilies[familyIndex].variants.isEmpty {
                        if selectedFont == family.name {
                            selectedFont = "System Default"
                            onSave()
                        }
                        customFamilies.remove(at: familyIndex)
                    }
                }
            }
        }
    }
}

private struct IOSUserHighlightColorControl: View {
    @Binding var hex: String
    let defaultHex: String
    let onSave: () -> Void
    @State private var localColor: Color = .yellow
    @State private var hexInput: String = ""
    @State private var isInitialized = false

    private var isDefault: Bool {
        hex.uppercased() == defaultHex.uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                hex = defaultHex
                localColor = Color(hex: defaultHex) ?? .yellow
                hexInput = defaultHex
                onSave()
            } label: {
                Text("Default")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isDefault ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundStyle(isDefault ? .white : .primary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            ColorPicker("", selection: $localColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 32)
                .onAppear {
                    localColor = Color(hex: hex) ?? .yellow
                    hexInput = hex
                    DispatchQueue.main.async { isInitialized = true }
                }
                .onChange(of: localColor) { _, newColor in
                    guard isInitialized else { return }
                    if let newHex = newColor.hexString() {
                        hex = newHex
                        hexInput = newHex
                        onSave()
                    }
                }

            TextField("#RRGGBB", text: $hexInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .frame(maxWidth: 100)
                .onSubmit {
                    if let color = Color(hex: hexInput) {
                        hex = hexInput.uppercased()
                        localColor = color
                        onSave()
                    } else {
                        hexInput = hex
                    }
                }
        }
    }
}

private struct IOSAppearanceColorControl: View {
    @Binding var hex: String?
    let defaultHex: String?
    let onSave: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var localColor: Color = .gray
    @State private var hexInput: String = ""
    @State private var isInitialized = false

    private var effectiveDefaultHex: String {
        defaultHex ?? (colorScheme == .dark ? "#333333" : "#888888")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                hex = nil
                localColor = Color(hex: effectiveDefaultHex) ?? .gray
                hexInput = ""
                onSave()
            } label: {
                Text("Default")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hex == nil ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundStyle(hex == nil ? .white : .primary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            ColorPicker("", selection: $localColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: 32)
                .onAppear {
                    localColor = Color(hex: hex ?? effectiveDefaultHex) ?? .gray
                    hexInput = hex ?? ""
                    DispatchQueue.main.async { isInitialized = true }
                }
                .onChange(of: localColor) { _, newColor in
                    guard isInitialized else { return }
                    if let newHex = newColor.hexString() {
                        hex = newHex
                        hexInput = newHex
                        onSave()
                    }
                }

            TextField("#RRGGBB", text: $hexInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .frame(maxWidth: 100)
                .onSubmit {
                    if hexInput.isEmpty {
                        hex = nil
                        localColor = Color(hex: effectiveDefaultHex) ?? .gray
                        onSave()
                    } else if let color = Color(hex: hexInput) {
                        hex = hexInput.uppercased()
                        localColor = color
                        onSave()
                    } else {
                        hexInput = hex ?? ""
                    }
                }
        }
    }
}
#endif
