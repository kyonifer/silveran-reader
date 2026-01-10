import Foundation
import SilveranKitCommon
import SwiftUI

@MainActor
@Observable
public final class TVSettingsViewModel {
    var serverURL: String = ""
    var username: String = ""
    var password: String = ""
    var connectionError: String?
    var isTesting: Bool = false
    var fontFamily: String = kDefaultFontFamily
    var tvSubtitleFontSize: Double = kDefaultTVSubtitleFontSize
    var customFontFamilies: [CustomFontFamily] = []

    init() {
        Task {
            await loadCredentials()
            await loadSettings()
            await loadCustomFonts()
        }
    }

    func loadSettings() async {
        let config = await SettingsActor.shared.config
        fontFamily = config.reading.fontFamily
        tvSubtitleFontSize = config.reading.tvSubtitleFontSize
    }

    func loadCustomFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFontFamilies = await CustomFontsActor.shared.availableFamilies
    }

    func updateFontFamily(_ newValue: String) async {
        fontFamily = newValue
        do {
            try await SettingsActor.shared.updateConfig(fontFamily: newValue)
        } catch {
            debugLog("[TVSettingsViewModel] Failed to save font setting: \(error)")
        }
    }

    func updateSubtitleFontSize(_ newValue: Double) async {
        tvSubtitleFontSize = newValue
        do {
            try await SettingsActor.shared.updateConfig(tvSubtitleFontSize: newValue)
        } catch {
            debugLog("[TVSettingsViewModel] Failed to save subtitle font size: \(error)")
        }
    }

    func loadCredentials() async {
        do {
            if let credentials = try await AuthenticationActor.shared.loadCredentials() {
                serverURL = credentials.url
                username = credentials.username
                password = credentials.password
            }
        } catch {
            debugLog("[TVSettingsViewModel] Failed to load credentials: \(error)")
        }
    }

    func testConnection() async {
        isTesting = true
        connectionError = nil

        let success = await StorytellerActor.shared.setLogin(
            baseURL: serverURL,
            username: username,
            password: password
        )

        if success {
            connectionError = nil
            await saveCredentials()
        } else {
            connectionError = "Failed to connect. Check your credentials."
        }

        isTesting = false
    }

    func saveCredentials() async {
        do {
            try await AuthenticationActor.shared.saveCredentials(
                url: serverURL,
                username: username,
                password: password
            )
            debugLog("[TVSettingsViewModel] Credentials saved")
        } catch {
            debugLog("[TVSettingsViewModel] Failed to save credentials: \(error)")
        }
    }

    func logout() async {
        do {
            try await AuthenticationActor.shared.deleteCredentials()
            serverURL = ""
            username = ""
            password = ""
            _ = await StorytellerActor.shared.logout()
            debugLog("[TVSettingsViewModel] Logged out")
        } catch {
            debugLog("[TVSettingsViewModel] Failed to logout: \(error)")
        }
    }
}
