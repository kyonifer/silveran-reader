# Architecture

Silveran is organized as one root Swift package plus app shells. The root manifest is [`Package.swift`](https://github.com/kyonifer/silveran-reader/blob/main/Package.swift), and the main source tree is [`SilveranKit/Sources`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources).

## SilveranKit

[`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) is the cross-platform core library. It owns the models, persistence, parsing, playback coordination, Storyteller API logic, migrations, and utility actors that all app shells use.

The root package exports it as the [`SilveranKit` SwiftPM product](https://github.com/kyonifer/silveran-reader/blob/main/Package.swift). Its dependency set should stay small and portable.

Important areas:

- [`Models`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Models) for shared data types.
- [`Actors`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Actors) for library, playback, downloads, Storyteller, and progress logic.
- [`EPUB`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/EPUB) for EPUB and SMIL parsing.
- [`Facades`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades), described below.

## Dependency Injection

The core library still needs platform functionality for things such as audio playback and keychain storage. Those dependencies are declared as protocols in [`SilveranKit/Sources/Kit/Facades`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades), then injected by app-facing packages.

There are two injection paths:

- [`SilveranPlatform`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/SilveranPlatform.swift) is a set-once platform service registry. Nonisolated core actors read it when they need platform services. App shells or platform packages call `SilveranPlatform.bootstrap(...)` during startup to select which platform implementation provides those services.
- [`SilveranEnvironment`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/SilveranEnvironment.swift) carries optional UI-level capabilities, currently content server support and readaloud alignment. Entry points receive it and pass it through the SwiftUI environment.

## SilveranAppleKit

[`SilveranAppleKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit) depends on `SilveranKit` and provides Apple implementations of the [`platform facade protocols`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades). Those implementations live in [`Shared/Platform`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/Shared/Platform):

- [`ApplePlatformBootstrap`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/ApplePlatformBootstrap.swift) installs default Apple providers unless a host app already bootstrapped custom providers.
- [`ApplePlayerProvider`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/ApplePlayerProvider.swift) implements audio playback with AVFoundation.
- [`MediaNowPlayingPresenter`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/MediaNowPlayingPresenter.swift) implements now-playing and remote command integration with MediaPlayer.
- [`AVAssetMetadataProbe`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/AVAssetMetadataProbe.swift) implements audio metadata probing with AVFoundation.
- [`SecurityKeychainStore`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/SecurityKeychainStore.swift) implements keychain storage with Security.
- [`CoreTextFontTraitsProbe`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/CoreTextFontTraitsProbe.swift) implements font trait probing with CoreText.

It also contains shared code that is only common among Apple platforms, plus UI code for the apps:

- [`MobileDesktop`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop) is the shared macOS and iOS app surface: library, player, settings, readaloud generation UI, and common view model code.
- [`macApp`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/macApp) contains the macOS shell around the shared mobile/desktop UI.
- [`iOSApp`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp) contains the iOS shell around the shared mobile/desktop UI.
- [`CarPlay`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/CarPlay) contains the iOS CarPlay scene integration.
- [`tvOS`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/tvOS) is its own TV app UI.
- [`watchOS`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/watchOS) is its own watch app UI.

Apple entry points live next to their platform apps:

- [`macAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/MobileDesktop/macApp/MacEntryPoint.swift)
- [`iosAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/iOSEntryPoint.swift)
- [`tvAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/tvOS/TVEntryPoint.swift)
- [`watchAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/watchOS/WatchEntryPoint.swift)

Optional products sit beside the core and Apple package:

- [`SilveranContentServer`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/ContentServer) implements the local content-server integration.
- [`SilveranReadaloud`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Readaloud) implements readaloud alignment.

## Apps

App shells live outside the core package targets. They wire platform build settings, resources, entitlements, and entry stubs around the package products.

[`XCodeApps`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps) contains the generated Xcode app definitions for Apple platforms:

- [`project.yml`](https://github.com/kyonifer/silveran-reader/blob/main/XCodeApps/project.yml) is the Xcode project definition. XcodeGen uses it to produce `Silveran.xcodeproj`.
- [`EntryPointStub.swift`](https://github.com/kyonifer/silveran-reader/blob/main/XCodeApps/EntryPointStub.swift) imports `SilveranAppleKit`, constructs a `SilveranEnvironment` with the optional products linked by each platform, and calls the platform entry point.
- [`Assets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/Assets.xcassets), [`WatchAssets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/WatchAssets.xcassets), and [`TVAssets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/TVAssets.xcassets) hold app icon and platform asset catalogs.
- The app Info.plist and entitlement files in [`XCodeApps`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps) define the local app identities, permissions, and platform settings.

[`LinuxApp`](https://github.com/kyonifer/silveran-reader/tree/main/LinuxApp) is a separate Swift package that depends on the root package through a local path dependency. It imports `SilveranKit` directly and provides Linux implementations of the [`platform facade protocols`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades). Those implementations live in [`LinuxApp/Sources/SilveranLinuxApp/Shared/Platform`](https://github.com/kyonifer/silveran-reader/tree/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform):

- [`LinuxPlatformBootstrap`](https://github.com/kyonifer/silveran-reader/blob/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform/LinuxPlatformBootstrap.swift) installs the available Linux providers.
- [`MpvPlayerProvider`](https://github.com/kyonifer/silveran-reader/blob/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform/MpvAudioEngine.swift) implements audio playback with mpv.
- `NowPlayingPresenting` is WIP.
- `AudioMetadataProbing` is WIP.
- `KeychainStoring` is WIP.
- `FontMetadataProbing` is WIP.

Build and run helpers live in [`scripts`](https://github.com/kyonifer/silveran-reader/tree/main/scripts):

- [`genxproj`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/genxproj) regenerates `Silveran.xcodeproj` from `XCodeApps/project.yml`.
- [`macbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/macbuild), [`iosbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/iosbuild), [`tvbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/tvbuild), and [`watchbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/watchbuild) build Apple targets.
- [`linuxbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/linuxbuild) and [`linuxrun`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/linuxrun) build and run the Linux app shell.

See [`CONTRIBUTING.md`](https://github.com/kyonifer/silveran-reader/blob/main/CONTRIBUTING.md) for local setup, build commands, and formatting expectations.
