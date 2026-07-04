#if os(iOS) || os(macOS)
import SwiftUI

struct ThemeEditorView: View {
    @Bindable var settingsVM: SettingsViewModel
    let theme: ReaderTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: ReaderTheme
    @State private var originalFlatValues: FlatColorSnapshot?

    init(settingsVM: SettingsViewModel, theme: ReaderTheme) {
        self.settingsVM = settingsVM
        self.theme = theme
        self._draft = State(initialValue: theme)
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            editorContent
                .navigationTitle("Edit Theme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancelEditing() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveEditing() }
                    }
                }
        }
        .onAppear { captureOriginalValues() }
        #else
        VStack(spacing: 0) {
            editorContent
                .frame(minWidth: 600, minHeight: 500)
            Divider()
            HStack {
                Button("Cancel") { cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveEditing() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear { captureOriginalValues() }
        #endif
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                nameField

                appearanceField

                Divider()

                readerColorsSection

                Divider()

                readaloudSection

                Divider()

                userHighlightsSection

                Divider()

                customCSSSection
            }
            .padding()
        }
        .onChange(of: draft) { _, newDraft in
            pushLivePreview(newDraft)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theme Name")
                .font(.headline)
            TextField("Theme Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                #if os(macOS)
            .frame(maxWidth: 300)
                #endif
        }
    }

    private var appearanceField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show In")
                .font(.headline)
            Picker("Show In", selection: $draft.appearance) {
                Text("Light & Dark").tag(ThemeAppearance.any)
                Text("Light Only").tag(ThemeAppearance.light)
                Text("Dark Only").tag(ThemeAppearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            .frame(maxWidth: 300)
            #endif
        }
    }

    private var readerColorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reader Colors")
                .font(.headline)

            editorColorRow(label: "Background", hex: $draft.backgroundColor)
            editorColorRow(label: "Text", hex: $draft.foregroundColor)
        }
    }

    private var readaloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Readaloud Highlight")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $draft.readaloudHighlightMode) {
                    Text("Background").tag("background")
                    Text("Text").tag("text")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .frame(maxWidth: 300)
                #endif
            }

            editorColorRow(label: "Highlight Color", hex: $draft.highlightColor)

            if draft.readaloudHighlightMode == "background" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Highlight Height: \(String(format: "%.1fx", draft.highlightThickness))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $draft.highlightThickness, in: 0.6...4.0, step: 0.1)
                        #if os(macOS)
                    .frame(maxWidth: 300)
                        #endif
                }
            }
        }
    }

    private var userHighlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("User Highlight Colors")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Highlight Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $draft.userHighlightMode) {
                    Text("Background").tag("background")
                    Text("Text").tag("text")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .frame(maxWidth: 300)
                #endif
            }

            labeledColorRow(label: $draft.userHighlightLabel1, hex: $draft.userHighlightColor1)
            labeledColorRow(label: $draft.userHighlightLabel2, hex: $draft.userHighlightColor2)
            labeledColorRow(label: $draft.userHighlightLabel3, hex: $draft.userHighlightColor3)
            labeledColorRow(label: $draft.userHighlightLabel4, hex: $draft.userHighlightColor4)
            labeledColorRow(label: $draft.userHighlightLabel5, hex: $draft.userHighlightColor5)
            labeledColorRow(label: $draft.userHighlightLabel6, hex: $draft.userHighlightColor6)
        }
    }

    private var customCSSSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom CSS")
                .font(.headline)
            TextEditor(
                text: Binding(
                    get: { draft.customCSS ?? "" },
                    set: { draft.customCSS = $0.isEmpty ? nil : $0 },
                )
            )
            .font(.system(.body, design: .monospaced))
            .frame(height: 100)
            #if os(macOS)
            .border(Color.secondary.opacity(0.3), width: 1)
            #endif
        }
    }

    @ViewBuilder
    private func editorColorRow(label: String, hex: Binding<String>) -> some View {
        ThemeColorControl(label: label, hex: hex)
    }

    @ViewBuilder
    private func labeledColorRow(label: Binding<String>, hex: Binding<String>) -> some View {
        HStack {
            TextField("Label", text: label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            ThemeColorControl(label: label.wrappedValue, hex: hex)
        }
    }

    private func captureOriginalValues() {
        originalFlatValues = FlatColorSnapshot(
            backgroundColor: settingsVM.backgroundColor,
            foregroundColor: settingsVM.foregroundColor,
            highlightColor: settingsVM.highlightColor,
            highlightThickness: settingsVM.highlightThickness,
            readaloudHighlightMode: settingsVM.readaloudHighlightMode,
            userHighlightColor1: settingsVM.userHighlightColor1,
            userHighlightColor2: settingsVM.userHighlightColor2,
            userHighlightColor3: settingsVM.userHighlightColor3,
            userHighlightColor4: settingsVM.userHighlightColor4,
            userHighlightColor5: settingsVM.userHighlightColor5,
            userHighlightColor6: settingsVM.userHighlightColor6,
            userHighlightLabel1: settingsVM.userHighlightLabel1,
            userHighlightLabel2: settingsVM.userHighlightLabel2,
            userHighlightLabel3: settingsVM.userHighlightLabel3,
            userHighlightLabel4: settingsVM.userHighlightLabel4,
            userHighlightLabel5: settingsVM.userHighlightLabel5,
            userHighlightLabel6: settingsVM.userHighlightLabel6,
            userHighlightMode: settingsVM.userHighlightMode,
            customCSS: settingsVM.customCSS,
        )
    }

    private func pushLivePreview(_ theme: ReaderTheme) {
        let isActive =
            settingsVM.activeThemeId(for: colorScheme) == theme.id
        guard isActive else { return }

        settingsVM.backgroundColor = theme.backgroundColor
        settingsVM.foregroundColor = theme.foregroundColor
        settingsVM.highlightColor = theme.highlightColor
        settingsVM.highlightThickness = theme.highlightThickness
        settingsVM.readaloudHighlightMode = theme.readaloudHighlightMode
        settingsVM.userHighlightColor1 = theme.userHighlightColor1
        settingsVM.userHighlightColor2 = theme.userHighlightColor2
        settingsVM.userHighlightColor3 = theme.userHighlightColor3
        settingsVM.userHighlightColor4 = theme.userHighlightColor4
        settingsVM.userHighlightColor5 = theme.userHighlightColor5
        settingsVM.userHighlightColor6 = theme.userHighlightColor6
        settingsVM.userHighlightLabel1 = theme.userHighlightLabel1
        settingsVM.userHighlightLabel2 = theme.userHighlightLabel2
        settingsVM.userHighlightLabel3 = theme.userHighlightLabel3
        settingsVM.userHighlightLabel4 = theme.userHighlightLabel4
        settingsVM.userHighlightLabel5 = theme.userHighlightLabel5
        settingsVM.userHighlightLabel6 = theme.userHighlightLabel6
        settingsVM.userHighlightMode = theme.userHighlightMode
        settingsVM.customCSS = theme.customCSS
        settingsVM.save()
    }

    private func saveEditing() {
        settingsVM.updateCustomTheme(draft)
        let isActive = settingsVM.activeThemeId(for: colorScheme) == draft.id
        if isActive {
            settingsVM.applyThemeValues(draft)
        }
        dismiss()
    }

    private func cancelEditing() {
        if let snap = originalFlatValues {
            settingsVM.backgroundColor = snap.backgroundColor
            settingsVM.foregroundColor = snap.foregroundColor
            settingsVM.highlightColor = snap.highlightColor
            settingsVM.highlightThickness = snap.highlightThickness
            settingsVM.readaloudHighlightMode = snap.readaloudHighlightMode
            settingsVM.userHighlightColor1 = snap.userHighlightColor1
            settingsVM.userHighlightColor2 = snap.userHighlightColor2
            settingsVM.userHighlightColor3 = snap.userHighlightColor3
            settingsVM.userHighlightColor4 = snap.userHighlightColor4
            settingsVM.userHighlightColor5 = snap.userHighlightColor5
            settingsVM.userHighlightColor6 = snap.userHighlightColor6
            settingsVM.userHighlightLabel1 = snap.userHighlightLabel1
            settingsVM.userHighlightLabel2 = snap.userHighlightLabel2
            settingsVM.userHighlightLabel3 = snap.userHighlightLabel3
            settingsVM.userHighlightLabel4 = snap.userHighlightLabel4
            settingsVM.userHighlightLabel5 = snap.userHighlightLabel5
            settingsVM.userHighlightLabel6 = snap.userHighlightLabel6
            settingsVM.userHighlightMode = snap.userHighlightMode
            settingsVM.customCSS = snap.customCSS
            settingsVM.save()
        }
        dismiss()
    }
}

private struct FlatColorSnapshot {
    let backgroundColor: String?
    let foregroundColor: String?
    let highlightColor: String?
    let highlightThickness: Double
    let readaloudHighlightMode: String
    let userHighlightColor1: String
    let userHighlightColor2: String
    let userHighlightColor3: String
    let userHighlightColor4: String
    let userHighlightColor5: String
    let userHighlightColor6: String
    let userHighlightLabel1: String
    let userHighlightLabel2: String
    let userHighlightLabel3: String
    let userHighlightLabel4: String
    let userHighlightLabel5: String
    let userHighlightLabel6: String
    let userHighlightMode: String
    let customCSS: String?
}

private struct ThemeColorControl: View {
    let label: String
    @Binding var hex: String
    @State private var localColor: Color = .gray
    @State private var hexInput: String = ""
    @State private var isInitialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ColorPicker("", selection: $localColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 28)
                    .onAppear {
                        localColor = Color(hex: hex) ?? .gray
                        hexInput = hex
                        DispatchQueue.main.async { isInitialized = true }
                    }
                    .onChange(of: localColor) { _, newColor in
                        guard isInitialized else { return }
                        if let newHex = newColor.hexString() {
                            hex = newHex
                            hexInput = newHex
                        }
                    }

                TextField("#RRGGBB", text: $hexInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                    #endif
                    .frame(maxWidth: 100)
                    .onSubmit {
                        if let color = Color(hex: hexInput) {
                            hex = hexInput.uppercased()
                            localColor = color
                        } else {
                            hexInput = hex
                        }
                    }
                    .onChange(of: hex) { _, newHex in
                        guard isInitialized else { return }
                        hexInput = newHex
                        if let color = Color(hex: newHex) {
                            localColor = color
                        }
                    }
            }
        }
    }
}

#endif
