import SwiftUI
import Observation

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
            _ = settingsVM.marginLeftRight
            _ = settingsVM.marginTopBottom
            _ = settingsVM.wordSpacing
            _ = settingsVM.letterSpacing
            _ = settingsVM.highlightColor
            _ = settingsVM.backgroundColor
            _ = settingsVM.foregroundColor
            _ = settingsVM.customCSS
            _ = settingsVM.singleColumnMode
        } onChange: {
            Task { @MainActor in
                await self.sendStyleUpdate()
                self.setupSettingsObserver()
            }
        }
    }

    func handleColorSchemeChange(_ newColorScheme: ColorScheme) {
        debugLog("[ReaderStyleManager] Color scheme changed to \(newColorScheme == .dark ? "dark" : "light")")
        colorScheme = newColorScheme
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

        debugLog("[ReaderStyleManager] Sending style update:")
        debugLog("[ReaderStyleManager]   fontSize: \(settingsVM.fontSize)")
        debugLog("[ReaderStyleManager]   fontFamily: \(settingsVM.fontFamily)")
        debugLog("[ReaderStyleManager]   isDarkMode: \(isDarkMode)")
        debugLog("[ReaderStyleManager]   backgroundColor: \(settingsVM.backgroundColor ?? "nil")")
        debugLog("[ReaderStyleManager]   foregroundColor: \(settingsVM.foregroundColor ?? "nil")")

        do {
            try await bridge.sendJsUpdateStyles(
                fontSize: settingsVM.fontSize,
                fontFamily: settingsVM.fontFamily,
                isDarkMode: isDarkMode,
                marginLeftRight: settingsVM.marginLeftRight,
                marginTopBottom: settingsVM.marginTopBottom,
                wordSpacing: settingsVM.wordSpacing,
                letterSpacing: settingsVM.letterSpacing,
                highlightColor: settingsVM.highlightColor,
                backgroundColor: settingsVM.backgroundColor,
                foregroundColor: settingsVM.foregroundColor,
                customCSS: settingsVM.customCSS,
                singleColumnMode: settingsVM.singleColumnMode
            )
            debugLog("[ReaderStyleManager] Style update sent successfully")
        } catch {
            debugLog("[ReaderStyleManager] Failed to send style update: \(error)")
        }
    }
}
