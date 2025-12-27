import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
private class SettingsReloader: ObservableObject {
    @Published var trigger = 0
    private var observerID: UUID?

    init() {
        Task {
            observerID = await SettingsActor.shared.request_notify { @MainActor [weak self] in
                self?.trigger += 1
            }
        }
    }

    deinit {
        if let id = observerID {
            Task {
                await SettingsActor.shared.removeObserver(id: id)
            }
        }
    }
}

public struct SettingsView: View {
    @State private var config = SilveranGlobalConfig()
    @State private var isLoaded = false
    @State private var saveError: String?
    @State private var showResetConfirmation = false
    @State private var persistTask: Task<Void, Never>?
    @StateObject private var reloader = SettingsReloader()
    #if os(macOS)
    @State private var selectedTab: SettingsTab = .general
    #endif

    public init() {}

    public var body: some View {
        ZStack {
            settingsContent
                .opacity(isLoaded ? 1 : 0.5)

            if !isLoaded {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task(loadConfig)
        .onChange(of: config) { _, newValue in persistConfig(newValue: newValue) }
        .onChange(of: reloader.trigger) { _, _ in
            Task { await reloadConfig() }
        }
        .alert(
            "Unable to Save Settings",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } },
            ),
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert(
            "Reset All Settings to Default?",
            isPresented: $showResetConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text(
                "This will reset all settings across all tabs to their default values. This action cannot be undone."
            )
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        #if os(macOS)
        macOSContent
        #else
        iosContent
        #endif
    }

    private func loadConfig() async {
        guard !isLoaded else { return }
        let loaded = await SettingsActor.shared.config
        await MainActor.run {
            config = loaded
            isLoaded = true
        }
    }

    private func reloadConfig() async {
        guard persistTask == nil else { return }
        let loaded = await SettingsActor.shared.config
        await MainActor.run {
            config = loaded
        }
    }

    private func persistConfig(newValue: SilveranGlobalConfig) {
        guard isLoaded else { return }

        persistTask?.cancel()
        persistTask = Task {
            defer { persistTask = nil }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            do {
                debugLog(
                    "[SettingsView] Persisting config - Progress: \(newValue.sync.progressSyncIntervalSeconds)s, Metadata: \(newValue.sync.metadataRefreshIntervalSeconds)s"
                )
                try await SettingsActor.shared.updateConfig(
                    fontSize: newValue.reading.fontSize,
                    fontFamily: newValue.reading.fontFamily,
                    marginLeftRight: newValue.reading.marginLeftRight,
                    marginTopBottom: newValue.reading.marginTopBottom,
                    wordSpacing: newValue.reading.wordSpacing,
                    letterSpacing: newValue.reading.letterSpacing,
                    highlightColor: .some(newValue.reading.highlightColor),
                    backgroundColor: .some(newValue.reading.backgroundColor),
                    foregroundColor: .some(newValue.reading.foregroundColor),
                    customCSS: .some(newValue.reading.customCSS),
                    enableMarginClickNavigation: newValue.reading.enableMarginClickNavigation,
                    singleColumnMode: newValue.reading.singleColumnMode,
                    defaultPlaybackSpeed: newValue.playback.defaultPlaybackSpeed,
                    enableReadingBar: newValue.readingBar.enabled,
                    showPlayerControls: newValue.readingBar.showPlayerControls,
                    showProgressBar: newValue.readingBar.showProgressBar,
                    showProgress: newValue.readingBar.showProgress,
                    showTimeRemainingInBook: newValue.readingBar.showTimeRemainingInBook,
                    showTimeRemainingInChapter: newValue.readingBar.showTimeRemainingInChapter,
                    showPageNumber: newValue.readingBar.showPageNumber,
                    overlayTransparency: newValue.readingBar.overlayTransparency,
                    alwaysShowMiniPlayer: newValue.readingBar.alwaysShowMiniPlayer,
                    progressSyncIntervalSeconds: newValue.sync.progressSyncIntervalSeconds,
                    metadataRefreshIntervalSeconds: newValue.sync.metadataRefreshIntervalSeconds,
                    iCloudSyncEnabled: newValue.sync.iCloudSyncEnabled,
                    userHighlightColor1: newValue.reading.userHighlightColor1,
                    userHighlightColor2: newValue.reading.userHighlightColor2,
                    userHighlightColor3: newValue.reading.userHighlightColor3,
                    userHighlightColor4: newValue.reading.userHighlightColor4,
                    userHighlightColor5: newValue.reading.userHighlightColor5,
                    userHighlightColor6: newValue.reading.userHighlightColor6
                )
                debugLog("[SettingsView] Config persisted successfully")
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                }
                debugLog("[SettingsView] Failed to persist config: \(error)")
            }
        }
    }

    private func resetAllSettings() {
        config = SilveranGlobalConfig()
    }
}

#if os(macOS)
extension SettingsView {
    fileprivate var macOSContent: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                MacGeneralSettingsView(sync: $config.sync)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }
                    .tag(SettingsTab.general)

                MacReaderSettingsView(reading: $config.reading, playback: $config.playback)
                    .tabItem {
                        Label("Reader Settings", systemImage: "textformat")
                    }
                    .tag(SettingsTab.readerSettings)

                MacReadingBarSettingsView(readingBar: $config.readingBar)
                    .tabItem {
                        Label("Overlay Stats", systemImage: "chart.bar")
                    }
                    .tag(SettingsTab.readingBar)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    showResetConfirmation = true
                } label: {
                    Label("Reset All to Default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 820, height: 580)
    }
}
#else
extension SettingsView {
    fileprivate var iosContent: some View {
        NavigationStack {
            Form {
                Section("General") {
                    GeneralSettingsFields(sync: $config.sync)
                }

                Section("Server Configuration") {
                    NavigationLink {
                        StorytellerServerSettingsView()
                    } label: {
                        Label("Storyteller Server", systemImage: "server.rack")
                    }
                }

                Section {
                    NavigationLink {
                        IOSDebugLogView()
                    } label: {
                        Label("Debug Log", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct IOSDebugLogView: View {
    @State private var logText: String = ""
    @State private var messageCount: Int = 0

    var body: some View {
        List {
            Section {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("\(messageCount) messages")
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    DebugLogBuffer.shared.clear()
                    loadMessages()
                } label: {
                    Image(systemName: "trash")
                }
                Button {
                    loadMessages()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            loadMessages()
        }
    }

    private func loadMessages() {
        let messages = DebugLogBuffer.shared.getMessages()
        messageCount = messages.count
        logText = messages.joined(separator: "\n")
    }
}
#endif

#if os(macOS)
private enum SettingsTab: Hashable {
    case general
    case readerSettings
    case readingBar
}

private struct MacSettingsContainer<Content: View>: View {
    let tab: SettingsTab
    let content: Content

    init(tab: SettingsTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct MacGeneralSettingsView: View {
    @Binding var sync: SilveranGlobalConfig.Sync
    @State private var showClearConfirmation = false
    private let labelWidth: CGFloat = 180

    private let syncIntervals: [Double] = [10, 30, 60, 120, 300, 600, 1800, 3600, 7200, 14400, -1]

    var body: some View {
        MacSettingsContainer(tab: .general) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Storyteller Server Sync")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow {
                        label("Progress Sync Interval")
                        HStack(spacing: 12) {
                            Slider(
                                value: Binding(
                                    get: {
                                        let index = indexForInterval(
                                            sync.progressSyncIntervalSeconds
                                        )
                                        //debugLog(.settingsView, "Progress Sync GET - current value: \(sync.progressSyncIntervalSeconds)s, index: \(index)")
                                        return index
                                    },
                                    set: { newIndex in
                                        let newValue = syncIntervals[Int(newIndex)]
                                        debugLog(
                                            "[SettingsView] Progress Sync SET - index: \(newIndex) -> value: \(newValue)s"
                                        )
                                        sync.progressSyncIntervalSeconds = newValue
                                    }
                                ),
                                in: 0...Double(syncIntervals.count - 1),
                                step: 1
                            )
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                            Text(formatInterval(sync.progressSyncIntervalSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }

                    GridRow {
                        label("Metadata Refresh Interval")
                        HStack(spacing: 12) {
                            Slider(
                                value: Binding(
                                    get: {
                                        let index = indexForInterval(
                                            sync.metadataRefreshIntervalSeconds
                                        )
                                        //debugLog(.settingsView, "Metadata Refresh GET - current value: \(sync.metadataRefreshIntervalSeconds)s, index: \(index)")
                                        return index
                                    },
                                    set: { newIndex in
                                        let newValue = syncIntervals[Int(newIndex)]
                                        debugLog(
                                            "[SettingsView] Metadata Refresh SET - index: \(newIndex) -> value: \(newValue)s"
                                        )
                                        sync.metadataRefreshIntervalSeconds = newValue
                                    }
                                ),
                                in: 0...Double(syncIntervals.count - 1),
                                step: 1
                            )
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                            Text(formatInterval(sync.metadataRefreshIntervalSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }

        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    private func indexForInterval(_ seconds: Double) -> Double {
        if let index = syncIntervals.firstIndex(of: seconds) {
            return Double(index)
        }
        if seconds < 0 {
            return Double(syncIntervals.count - 1)
        }
        let closest = syncIntervals.enumerated().min(by: {
            abs($0.element - seconds) < abs($1.element - seconds)
        })
        return Double(closest?.offset ?? 0)
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds < 0 {
            return "Never"
        }
        let s = Int(seconds)
        if s < 60 {
            return "\(s)s"
        } else if s < 3600 {
            return "\(s / 60)m"
        } else {
            return "\(s / 3600)h"
        }
    }
}

private struct MacReaderSettingsView: View {
    @Binding var reading: SilveranGlobalConfig.Reading
    @Binding var playback: SilveranGlobalConfig.Playback
    private let labelWidth: CGFloat = 150

    var body: some View {
        MacSettingsContainer(tab: .readerSettings) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                GridRow {
                    label("Font Size")
                    Stepper(value: $reading.fontSize, in: 8...60, step: 1) {
                        Text("\(Int(reading.fontSize)) pt")
                    }
                    .frame(width: 200, alignment: .leading)
                }

                GridRow {
                    label("Single Column")
                    Toggle("", isOn: $reading.singleColumnMode)
                        .labelsHidden()
                        .frame(width: 200, alignment: .leading)
                }

                GridRow {
                    label("Font")
                    Picker("", selection: $reading.fontFamily) {
                        Text("System Default").tag("System Default")
                        Text("Serif").tag("serif")
                        Text("Sans-Serif").tag("sans-serif")
                        Text("Monospace").tag("monospace")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                GridRow {
                    label("Margin (Left/Right)")
                    MacSliderControl(
                        value: $reading.marginLeftRight,
                        range: 0...30,
                        step: 1,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }

                GridRow {
                    label("Margin (Top/Bottom)")
                    MacSliderControl(
                        value: $reading.marginTopBottom,
                        range: 0...30,
                        step: 1,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }

                GridRow {
                    label("Word Spacing")
                    MacSliderControl(
                        value: $reading.wordSpacing,
                        range: -0.5...2.0,
                        step: 0.1,
                        formatter: { String(format: "%.1fem", $0) }
                    )
                }

                GridRow {
                    label("Letter Spacing")
                    MacSliderControl(
                        value: $reading.letterSpacing,
                        range: -0.1...0.5,
                        step: 0.01,
                        formatter: { String(format: "%.2fem", $0) }
                    )
                }

                GridRow {
                    label("Playback Speed")
                    MacSliderControl(
                        value: $playback.defaultPlaybackSpeed,
                        range: 0.5...3.0,
                        step: 0.05,
                        formatter: { String(format: "%.2fx", $0) }
                    )
                }
            }

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 18) {
                Text("Navigation")
                    .font(.headline)

                Toggle(
                    "Enable margin click to turn pages",
                    isOn: $reading.enableMarginClickNavigation
                )
                .help("Click on the left or right margins of the page to navigate between pages")
            }

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 18) {
                Text("Appearance")
                    .font(.headline)

                HStack(alignment: .top, spacing: 48) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                        GridRow {
                            label("Read Aloud Highlight")
                            AppearanceColorControl(
                                hex: $reading.highlightColor,
                                isRequired: false,
                                defaultLightColor: "#CCCCCC",
                                defaultDarkColor: "#333333"
                            )
                        }

                        GridRow {
                            label("Background Color")
                            AppearanceColorControl(
                                hex: $reading.backgroundColor,
                                isRequired: false,
                                defaultLightColor: kDefaultBackgroundColorLight,
                                defaultDarkColor: kDefaultBackgroundColorDark
                            )
                        }

                        GridRow {
                            label("Foreground Color")
                            AppearanceColorControl(
                                hex: $reading.foregroundColor,
                                isRequired: false,
                                defaultLightColor: kDefaultForegroundColorLight,
                                defaultDarkColor: kDefaultForegroundColorDark
                            )
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                        GridRow {
                            label("Highlight #1 (Yellow)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor1, defaultHex: "#B5B83E")
                        }
                        GridRow {
                            label("Highlight #2 (Blue)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor2, defaultHex: "#4E90C7")
                        }
                        GridRow {
                            label("Highlight #3 (Green)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor3, defaultHex: "#198744")
                        }
                        GridRow {
                            label("Highlight #4 (Pink)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor4, defaultHex: "#E25EA3")
                        }
                        GridRow {
                            label("Highlight #5 (Orange)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor5, defaultHex: "#CE8C4A")
                        }
                        GridRow {
                            label("Highlight #6 (Purple)")
                            UserHighlightColorControl(hex: $reading.userHighlightColor6, defaultHex: "#B366FF")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom CSS")
                        .foregroundStyle(.secondary)
                    TextEditor(
                        text: Binding(
                            get: { reading.customCSS ?? "" },
                            set: { reading.customCSS = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 100)
                    .border(Color.secondary.opacity(0.3), width: 1)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}

private struct MacReadingBarSettingsView: View {
    @Binding var readingBar: SilveranGlobalConfig.ReadingBar

    var body: some View {
        MacSettingsContainer(tab: .readingBar) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Enable Overlay Stats", isOn: $readingBar.enabled)
                    .font(.headline)

                Divider()

                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transparency: \(Int(readingBar.overlayTransparency * 100))%")
                            .font(.subheadline)
                        Slider(
                            value: $readingBar.overlayTransparency,
                            in: 0.1...1.0,
                            step: 0.01
                        )
                    }

                    Toggle("Show Player Controls", isOn: $readingBar.showPlayerControls)
                    Toggle("Show Progress Bar", isOn: $readingBar.showProgressBar)
                    Toggle("Show Page Number in Chapter", isOn: $readingBar.showPageNumber)
                    Toggle("Show Book Progress (%)", isOn: $readingBar.showProgress)
                    Toggle(
                        "Show Time Remaining in Chapter",
                        isOn: $readingBar.showTimeRemainingInChapter,
                    )
                    Toggle("Show Time Remaining in Book", isOn: $readingBar.showTimeRemainingInBook)
                }
                .disabled(!readingBar.enabled)
                .opacity(readingBar.enabled ? 1.0 : 0.5)
            }
        }
    }
}

private struct MacSliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    @State private var localValue: Double = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var isUpdatingFromSlider = false

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $localValue, in: range, step: step)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                .onAppear {
                    localValue = value
                }
                .onChange(of: localValue) { _, newValue in
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isUpdatingFromSlider = true
                            value = newValue
                            isUpdatingFromSlider = false
                        }
                    }
                }
                .onChange(of: value) { _, newValue in
                    guard !isUpdatingFromSlider else { return }
                    localValue = newValue
                }
            Text(formatter(localValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

#endif

private struct ReadingSettingsFields: View {
    @Binding var reading: SilveranGlobalConfig.Reading
    @Binding var playback: SilveranGlobalConfig.Playback

    var body: some View {
        #if os(macOS)
        EmptyView()
        #else
        Stepper(value: $reading.fontSize, in: 8...60, step: 1) {
            Text("Font Size: \(Int(reading.fontSize)) pt")
        }

        Toggle("Single Column", isOn: $reading.singleColumnMode)

        Picker("Font", selection: $reading.fontFamily) {
            Text("System Default").tag("System Default")
            Text("Serif").tag("serif")
            Text("Sans-Serif").tag("sans-serif")
            Text("Monospace").tag("monospace")
        }

        sliderBlock(
            title: "Margin (Left/Right)",
            value: $reading.marginLeftRight,
            range: 0...30,
            step: 1,
            formatted: { String(format: "%.0f%%", $0) }
        )

        sliderBlock(
            title: "Margin (Top/Bottom)",
            value: $reading.marginTopBottom,
            range: 0...30,
            step: 1,
            formatted: { String(format: "%.0f%%", $0) }
        )

        sliderBlock(
            title: "Word Spacing",
            value: $reading.wordSpacing,
            range: -0.5...2.0,
            step: 0.1,
            formatted: { String(format: "%.1fem", $0) }
        )

        sliderBlock(
            title: "Letter Spacing",
            value: $reading.letterSpacing,
            range: -0.1...0.5,
            step: 0.01,
            formatted: { String(format: "%.2fem", $0) }
        )

        highlightColorRow

        sliderBlock(
            title: "Default Playback Speed",
            value: $playback.defaultPlaybackSpeed,
            range: 0.5...3.0,
            step: 0.05,
            formatted: { String(format: "%.2fx", $0) }
        )
        #endif
    }

    private func sliderBlock(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatted: @escaping (Double) -> String,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                Text(formatted(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }

    private var highlightColorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Highlight Color")
                .font(.subheadline)
                .foregroundStyle(.primary)
            AppearanceColorControl(
                hex: $reading.highlightColor,
                isRequired: false,
                defaultLightColor: "#CCCCCC",
                defaultDarkColor: "#333333"
            )
        }
    }
}

private struct GeneralSettingsFields: View {
    @Binding var sync: SilveranGlobalConfig.Sync
    @State private var showClearConfirmation = false

    private let syncIntervals: [Double] = [10, 30, 60, 120, 300, 600, 1800, 3600, 7200, 14400, -1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress Sync Interval")
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Picker(
                    "",
                    selection: Binding(
                        get: { sync.progressSyncIntervalSeconds },
                        set: { sync.progressSyncIntervalSeconds = $0 }
                    )
                ) {
                    ForEach(syncIntervals, id: \.self) { interval in
                        Text(formatInterval(interval)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata Refresh Interval")
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Picker(
                    "",
                    selection: Binding(
                        get: { sync.metadataRefreshIntervalSeconds },
                        set: { sync.metadataRefreshIntervalSeconds = $0 }
                    )
                ) {
                    ForEach(syncIntervals, id: \.self) { interval in
                        Text(formatInterval(interval)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds < 0 {
            return "Never"
        }
        let s = Int(seconds)
        if s < 60 {
            return "\(s) seconds"
        } else if s < 3600 {
            let m = s / 60
            return "\(m) minute\(m == 1 ? "" : "s")"
        } else {
            let h = s / 3600
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
    }
}

private struct ReadingBarSettingsFields: View {
    @Binding var readingBar: SilveranGlobalConfig.ReadingBar

    var body: some View {
        Toggle("Enable Overlay Stats", isOn: $readingBar.enabled)

        VStack(alignment: .leading, spacing: 4) {
            Text("Transparency: \(Int(readingBar.overlayTransparency * 100))%")
            Slider(
                value: $readingBar.overlayTransparency,
                in: 0.1...1.0,
                step: 0.01
            )
        }
        .disabled(!readingBar.enabled)

        Toggle("Show Player Controls", isOn: $readingBar.showPlayerControls)
            .disabled(!readingBar.enabled)
        Toggle("Show Progress Bar", isOn: $readingBar.showProgressBar)
            .disabled(!readingBar.enabled)
        Toggle("Show Page Number in Chapter", isOn: $readingBar.showPageNumber)
            .disabled(!readingBar.enabled)
        Toggle("Show Book Progress (%)", isOn: $readingBar.showProgress)
            .disabled(!readingBar.enabled)
        Toggle("Show Time Remaining in Chapter", isOn: $readingBar.showTimeRemainingInChapter)
            .disabled(!readingBar.enabled)
        Toggle("Show Time Remaining in Book", isOn: $readingBar.showTimeRemainingInBook)
            .disabled(!readingBar.enabled)
    }
}

private struct UserHighlightColorControl: View {
    @Binding var hex: String
    let defaultHex: String
    @State private var localColor: Color = .yellow
    @State private var debounceTask: Task<Void, Never>?
    @State private var isUpdatingFromPicker = false

    private var isDefault: Bool {
        hex.uppercased() == defaultHex.uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                hex = defaultHex
                localColor = Color(hex: defaultHex) ?? .yellow
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

            ColorPicker(
                "",
                selection: $localColor,
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 48, height: 28)
            .onAppear {
                localColor = Color(hex: hex) ?? .yellow
            }
            .onChange(of: localColor) { _, newColor in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    if let newHex = newColor.hexString() {
                        await MainActor.run {
                            isUpdatingFromPicker = true
                            hex = newHex
                            isUpdatingFromPicker = false
                        }
                    }
                }
            }

            TextField("#RRGGBB", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                #endif
                .frame(maxWidth: 100)
                .onChange(of: hex) { _, newHex in
                    guard !isUpdatingFromPicker else { return }
                    if let color = Color(hex: newHex) {
                        localColor = color
                    }
                }
        }
    }
}

private struct AppearanceColorControl: View {
    let hex: Binding<String?>
    let isRequired: Bool
    let defaultLightColor: String?
    let defaultDarkColor: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var localColor: Color = .gray
    @State private var debounceTask: Task<Void, Never>?
    @State private var isUpdatingFromPicker = false

    init(
        hex: Binding<String?>,
        isRequired: Bool,
        defaultLightColor: String? = nil,
        defaultDarkColor: String? = nil
    ) {
        self.hex = hex
        self.isRequired = isRequired
        self.defaultLightColor = defaultLightColor
        self.defaultDarkColor = defaultDarkColor
    }

    init(hex: Binding<String>, isRequired: Bool) {
        self.hex = Binding(
            get: { hex.wrappedValue },
            set: { hex.wrappedValue = $0 ?? "#333333" }
        )
        self.isRequired = isRequired
        self.defaultLightColor = nil
        self.defaultDarkColor = nil
    }

    private var defaultHex: String {
        (colorScheme == .dark ? defaultDarkColor : defaultLightColor) ?? "#888888"
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { hex.wrappedValue ?? "" },
            set: { hex.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            if !isRequired {
                Button {
                    hex.wrappedValue = nil
                } label: {
                    Text("Default")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(hex.wrappedValue == nil ? Color.accentColor : Color.secondary.opacity(0.2))
                        .foregroundStyle(hex.wrappedValue == nil ? .white : .primary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            ColorPicker(
                "",
                selection: $localColor,
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 48, height: 28)
            .onAppear {
                localColor = Color(hex: hex.wrappedValue ?? defaultHex) ?? .gray
            }
            .onChange(of: localColor) { _, newColor in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    if let newHex = newColor.hexString() {
                        await MainActor.run {
                            isUpdatingFromPicker = true
                            hex.wrappedValue = newHex
                            isUpdatingFromPicker = false
                        }
                    }
                }
            }

            TextField("#RRGGBB", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                #endif
                .frame(maxWidth: 100)
                .onChange(of: hex.wrappedValue) { _, newHex in
                    guard !isUpdatingFromPicker else { return }
                    if let h = newHex, let color = Color(hex: h) {
                        localColor = color
                    }
                }
        }
    }
}

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        self = Color(red: r, green: g, blue: b)
    }

    #if os(macOS)
    func hexString() -> String? {
        let nsColor = NSColor(self)
        if let converted = nsColor.usingColorSpace(.sRGB) {
            let r = Int(round(converted.redComponent * 255))
            let g = Int(round(converted.greenComponent * 255))
            let b = Int(round(converted.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        if let converted = nsColor.usingColorSpace(.deviceRGB) {
            let r = Int(round(converted.redComponent * 255))
            let g = Int(round(converted.greenComponent * 255))
            let b = Int(round(converted.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    #else
    func hexString() -> String? {
        let uiColor = UIColor(self)
        guard
            let converted = uiColor.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!,
                intent: .defaultIntent,
                options: nil,
            ),
            let components = converted.components
        else {
            return nil
        }
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        return String(
            format: "#%02X%02X%02X",
            Int(round(r * 255)),
            Int(round(g * 255)),
            Int(round(b * 255)),
        )
    }
    #endif
}
