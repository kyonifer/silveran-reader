import Foundation
import SilveranKit

@MainActor
public func bootstrapLinuxPlatformDefaultsIfNeeded() {
    guard !SilveranPlatform.isBootstrapped else { return }
    #if canImport(CMpv)
    SilveranPlatform.bootstrap(audioPlayers: MpvPlayerProvider())
    #else
    SilveranPlatform.bootstrap()
    #endif
}
