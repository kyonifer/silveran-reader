import Observation
import SwiftUI

@MainActor
@Observable
class ReaderStyleManager {
    private weak var bridge: WebViewCommsBridge?
    private var settingsVM: SettingsViewModel
    private var colorScheme: ColorScheme = .light
    private var styleUpdateTask: Task<Void, Never>?
    private var fontFaceCSS: String = ""
    @ObservationIgnored private var fontObserverID: UUID?

    init(settingsVM: SettingsViewModel, bridge: WebViewCommsBridge) {
        self.settingsVM = settingsVM
        self.bridge = bridge
        setupSettingsObserver()
        Task {
            await refreshFontFaceCSS()
            await registerFontObserver()
        }
    }

    func cleanup() {
        if let id = fontObserverID {
            let capturedId = id
            fontObserverID = nil
            Task {
                await CustomFontsActor.shared.removeObserver(id: capturedId)
            }
        }
    }

    private func registerFontObserver() async {
        fontObserverID = await CustomFontsActor.shared.addObserver { @MainActor [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.fontFaceCSS = await CustomFontsActor.shared.fontFaceCSS
                await self.sendStyleUpdate()
            }
        }
    }

    func refreshFontFaceCSS() async {
        await CustomFontsActor.shared.refreshFonts()
        fontFaceCSS = await CustomFontsActor.shared.fontFaceCSS
        await sendStyleUpdate()
    }

    func updateBridge(_ bridge: WebViewCommsBridge) {
        self.bridge = bridge
    }

    func sendInitialStyles(colorScheme scheme: ColorScheme) {
        colorScheme = scheme
        Task { @MainActor in
            await sendStyleUpdate()
        }
    }

    private func setupSettingsObserver() {
        withObservationTracking {
            _ = settingsVM.fontSize
            _ = settingsVM.fontFamily
            _ = settingsVM.lineSpacing
            _ = settingsVM.marginLeftRight
            _ = settingsVM.marginTopBottom
            _ = settingsVM.wordSpacing
            _ = settingsVM.letterSpacing
            _ = settingsVM.highlightColor
            _ = settingsVM.backgroundColor
            _ = settingsVM.foregroundColor
            _ = settingsVM.customCSS
            _ = settingsVM.singleColumnMode
            _ = settingsVM.enableMarginClickNavigation
        } onChange: {
            Task { @MainActor in
                self.scheduleStyleUpdate()
                self.setupSettingsObserver()
            }
        }
    }

    private func scheduleStyleUpdate() {
        styleUpdateTask?.cancel()
        styleUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await sendStyleUpdate()
        }
    }

    func handleColorSchemeChange(_ newColorScheme: ColorScheme) {
        colorScheme = newColorScheme
        Task { @MainActor in
            await sendStyleUpdate()
        }
    }

    private func sendStyleUpdate() async {
        guard let bridge = bridge else { return }

        let isDarkMode = colorScheme == .dark

        let highlightColorRaw = settingsVM.highlightColor
        let backgroundColorRaw = settingsVM.backgroundColor
        let foregroundColorRaw = settingsVM.foregroundColor

        let effectiveHighlightColor =
            (highlightColorRaw?.isEmpty == false ? highlightColorRaw : nil)
            ?? (isDarkMode ? "#333333" : "#CCCCCC")
        let effectiveBackgroundColor =
            (backgroundColorRaw?.isEmpty == false ? backgroundColorRaw : nil)
            ?? (isDarkMode ? kDefaultBackgroundColorDark : kDefaultBackgroundColorLight)
        let effectiveForegroundColor =
            (foregroundColorRaw?.isEmpty == false ? foregroundColorRaw : nil)
            ?? (isDarkMode ? kDefaultForegroundColorDark : kDefaultForegroundColorLight)

        var effectiveCustomCSS = fontFaceCSS
        if let userCSS = settingsVM.customCSS, !userCSS.isEmpty {
            effectiveCustomCSS += "\n" + userCSS
        }

        try? await bridge.sendJsUpdateStyles(
            fontSize: settingsVM.fontSize,
            fontFamily: settingsVM.fontFamily,
            lineSpacing: settingsVM.lineSpacing,
            isDarkMode: isDarkMode,
            marginLeftRight: settingsVM.marginLeftRight,
            marginTopBottom: settingsVM.marginTopBottom,
            wordSpacing: settingsVM.wordSpacing,
            letterSpacing: settingsVM.letterSpacing,
            highlightColor: effectiveHighlightColor,
            backgroundColor: effectiveBackgroundColor,
            foregroundColor: effectiveForegroundColor,
            customCSS: effectiveCustomCSS.isEmpty ? nil : effectiveCustomCSS,
            singleColumnMode: settingsVM.singleColumnMode,
            enableMarginClickNavigation: settingsVM.enableMarginClickNavigation
        )
    }
}
