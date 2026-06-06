import SwiftUI
import UniformTypeIdentifiers

struct EbookPlayerSettings: View {
    @Bindable var settingsVM: SettingsViewModel
    let hasAudioNarration: Bool
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    let onDismiss: (() -> Void)?

    @State private var fontSizeInput: String = "20"
    #if os(iOS)
    @State private var customFamilies: [CustomFontFamily] = []
    @State private var showFontManager = false
    @State private var showManageThemes = false
    #endif

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
                formatter: { "\(Int($0))%" },
            )

            labeledSlider(
                label: "Margins (Top/Bottom)",
                value: $settingsVM.marginTopBottom,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" },
            )

            Divider()

            Toggle("Scrolling Mode", isOn: $settingsVM.scrollingMode)
                .onChange(of: settingsVM.scrollingMode) { _, _ in
                    settingsVM.save()
                }

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

                    if isCustomFont(settingsVM.fontFamily)
                        && !customFamilies.contains(where: { $0.name == settingsVM.fontFamily })
                    {
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
                        onSave: { settingsVM.save() },
                    )
                }
            }

            Toggle("Single Column", isOn: singleColumnBinding)
                .onChange(of: settingsVM.singleColumnMode) { _, _ in
                    settingsVM.save()
                }
                .disabled(settingsVM.scrollingMode)

            Toggle("Scrolling Mode", isOn: $settingsVM.scrollingMode)
                .onChange(of: settingsVM.scrollingMode) { _, _ in
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
                formatter: { String(format: "%.1f", $0) },
            )

            Divider()

            labeledSlider(
                label: "Margins (Left/Right)",
                value: $settingsVM.marginLeftRight,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" },
            )

            labeledSlider(
                label: "Margins (Top/Bottom)",
                value: $settingsVM.marginTopBottom,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" },
            )

            Divider()

            labeledSlider(
                label: "Word Spacing",
                value: $settingsVM.wordSpacing,
                range: -0.5...2.0,
                step: 0.1,
                formatter: { String(format: "%.1fem", $0) },
            )

            labeledSlider(
                label: "Letter Spacing",
                value: $settingsVM.letterSpacing,
                range: -0.1...0.5,
                step: 0.01,
                formatter: { String(format: "%.2fem", $0) },
            )

            Divider()

            Text("Themes")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Light Mode Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Light Mode Theme", selection: $settingsVM.selectedLightThemeId) {
                    ForEach(settingsVM.lightThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settingsVM.selectedLightThemeId) { _, _ in
                    settingsVM.applyActiveTheme(for: colorScheme)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Dark Mode Theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Dark Mode Theme", selection: $settingsVM.selectedDarkThemeId) {
                    ForEach(settingsVM.darkThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settingsVM.selectedDarkThemeId) { _, _ in
                    settingsVM.applyActiveTheme(for: colorScheme)
                }
            }

            Button {
                showManageThemes = true
            } label: {
                Label("Manage Themes...", systemImage: "paintpalette")
            }
            .sheet(isPresented: $showManageThemes) {
                ManageThemesView(settingsVM: settingsVM)
                    #if os(iOS)
                .presentationDetents([.fraction(0.7)])
                    #endif
            }
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

    #endif

    @ViewBuilder
    private func labeledSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: (Double) -> String,
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
        settingsVM.fontSize = kDefaultFontSize
        settingsVM.fontFamily = kDefaultFontFamily
        settingsVM.lineSpacing = kDefaultLineSpacing
        #if os(iOS)
        settingsVM.marginLeftRight = kDefaultMarginLeftRightIOS
        #else
        settingsVM.marginLeftRight = kDefaultMarginLeftRightMac
        #endif
        settingsVM.marginTopBottom = kDefaultMarginTopBottom
        settingsVM.wordSpacing = kDefaultWordSpacing
        settingsVM.letterSpacing = kDefaultLetterSpacing
        settingsVM.enableMarginClickNavigation = kDefaultEnableMarginClickNavigation
        settingsVM.scrollingMode = kDefaultScrollingMode
        settingsVM.enableReadingBar = kDefaultReadingBarEnabled
        settingsVM.showProgressBar = kDefaultShowProgressBar
        settingsVM.showProgress = kDefaultShowProgress
        settingsVM.showTimeRemainingInBook = kDefaultShowTimeRemainingInBook
        settingsVM.showTimeRemainingInChapter = kDefaultShowTimeRemainingInChapter
        settingsVM.showPageNumber = kDefaultShowPageNumber
        settingsVM.overlayTransparency = kDefaultOverlayTransparency
        settingsVM.singleColumnMode = kDefaultSingleColumnMode
        #if os(iOS)
        settingsVM.showPlayerControls = kDefaultShowPlayerControlsIOS
        settingsVM.showOverlaySkipBackward = kDefaultShowOverlaySkipBackward
        settingsVM.showOverlaySkipForward = kDefaultShowOverlaySkipForward
        #else
        settingsVM.showPlayerControls = kDefaultShowPlayerControlsMac
        #endif
        settingsVM.lockViewToAudio = kDefaultLockViewToAudio

        settingsVM.save()
    }

    private func isCustomFont(_ fontFamily: String) -> Bool {
        !["System Default", "serif", "sans-serif", "monospace"].contains(fontFamily)
    }

    private var singleColumnBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.singleColumnMode || settingsVM.scrollingMode },
            set: { settingsVM.singleColumnMode = $0 },
        )
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
                            UTType.font,
                        ],
                        allowsMultipleSelection: true,
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
                                        Text(
                                            "\(family.variants.count) variant\(family.variants.count == 1 ? "" : "s")"
                                        )
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

#endif
