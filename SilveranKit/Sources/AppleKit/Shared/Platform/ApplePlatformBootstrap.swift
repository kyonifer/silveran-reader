import Foundation

/// Installs the Apple implementations of the platform services unless the app
/// shell already bootstrapped its own. Called by every entry point so external
/// consumers get working audio/keychain/fonts without extra setup; a shell
/// that wants custom providers calls SilveranPlatform.bootstrap first.
public func bootstrapApplePlatformDefaultsIfNeeded() {
    AppleTemporaryFileCleaner.cleanAbandonedFilesOnce(
        in: FileManager.default.temporaryDirectory
    )
    guard !SilveranPlatform.isBootstrapped else { return }
    SilveranPlatform.bootstrap(
        audioPlayerFactory: AppleAudioPlayerFactory(),
        nowPlaying: MediaNowPlayingPresenter(),
        audioMetadata: AVAssetMetadataProbe(),
        keychain: SecurityKeychainStore(),
        fontMetadata: CoreTextFontTraitsProbe(),
        folderWatcher: applePlatformFolderWatcher(),
        applicationStorage: AppleApplicationStorageProvider(),
    )
}
