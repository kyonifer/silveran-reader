import Observation
import SwiftUI

@MainActor
@Observable
class ReaderStyleManager {
    private weak var bridge: WebViewCommsBridge?
    private var settingsVM: SettingsViewModel
    private var colorScheme: ColorScheme = .light

    init(settingsVM: SettingsViewModel, bridge: WebViewCommsBridge) {
        self.settingsVM = settingsVM
        self.bridge = bridge

        debugLog("[ReaderStyleManager] ReaderStyleManager initialized")

        setupSettingsObserver()
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
                await self.sendStyleUpdate()
                self.setupSettingsObserver()
            }
        }
    }

    func handleColorSchemeChange(_ newColorScheme: ColorScheme) {
        let oldScheme = colorScheme
        colorScheme = newColorScheme
        debugLog(
            "[ReaderStyleManager] Color scheme changed: \(oldScheme == .dark ? "dark" : "light") -> \(newColorScheme == .dark ? "dark" : "light")"
        )
        Task { @MainActor in
            await sendStyleUpdate()
        }
    }

    private func sendStyleUpdate() async {
        guard let bridge = bridge else {
            debugLog("[ReaderStyleManager] Bridge not available, skipping style update")
            return
        }

        let isDarkMode = colorScheme == .dark

        let effectiveHighlightColor =
            settingsVM.highlightColor ?? (isDarkMode ? "#333333" : "#CCCCCC")
        let effectiveBackgroundColor =
            settingsVM.backgroundColor
            ?? (isDarkMode ? kDefaultBackgroundColorDark : kDefaultBackgroundColorLight)
        let effectiveForegroundColor =
            settingsVM.foregroundColor
            ?? (isDarkMode ? kDefaultForegroundColorDark : kDefaultForegroundColorLight)

        debugLog("[ReaderStyleManager] Sending style update:")
        debugLog("[ReaderStyleManager]   isDarkMode: \(isDarkMode)")
        debugLog(
            "[ReaderStyleManager]   highlightColor (raw): \(settingsVM.highlightColor ?? "nil")"
        )
        debugLog("[ReaderStyleManager]   highlightColor (effective): \(effectiveHighlightColor)")
        debugLog("[ReaderStyleManager]   backgroundColor: \(effectiveBackgroundColor)")
        debugLog("[ReaderStyleManager]   foregroundColor: \(effectiveForegroundColor)")

        do {
            try await bridge.sendJsUpdateStyles(
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
                customCSS: settingsVM.customCSS,
                singleColumnMode: settingsVM.singleColumnMode,
                enableMarginClickNavigation: settingsVM.enableMarginClickNavigation
            )
            debugLog("[ReaderStyleManager] Style update sent successfully")
        } catch {
            debugLog("[ReaderStyleManager] Failed to send style update: \(error)")
        }
    }
}
