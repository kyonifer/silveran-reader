import Foundation
import SilveranKit

@MainActor
public func bootstrapLinuxPlatformDefaultsIfNeeded() {
    guard !SilveranPlatform.isBootstrapped else { return }
    #if canImport(CMpv)
    SilveranPlatform.bootstrap(
        audioPlayerFactory: MpvAudioPlayerFactory(),
        folderWatcher: PollingFolderWatcher(),
    )
    #else
    SilveranPlatform.bootstrap(folderWatcher: PollingFolderWatcher())
    #endif
}
