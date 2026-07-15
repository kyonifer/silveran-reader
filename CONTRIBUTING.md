# Contributing

## Architecture

Read [ARCHITECTURE.md](ARCHITECTURE.md) first. It maps the SwiftPM products, dependency injection model, Apple package, and app shells that make up this repository.

## Building on macOS

### Preparation

- Run `git submodule update --init` to checkout the bundled resources.
- Install `xcodegen` and `xcbeautify` from Homebrew.
- Install Xcode CLI Tools and accept the Xcode license
- Copy `XCodeApps/Configs/Local.example.xcconfig` to `XCodeApps/Configs/Local.xcconfig`.
- Set `DEVELOPMENT_TEAM` in that file, and optionally override the bundle IDs and keychain settings for your local signing namespace.
- Run `scripts/genxproj` before your initial build, or whenever `project.yml` changes. This script generates `Silveran.xcodeproj`.
- Run `scripts/genicons` if you want the icon to have the correct icon. You will need `imagemagick` from Homebrew for this step.

### Building Using XCode

- Open the generated `Silveran.xcodeproj` file and use Xcode to build the project for your desired target.

### Building Using the Terminal

- Run `scripts/macbuild` and `scripts/iosbuild` to build in the terminal for those respective targets.
- Run `scripts/macrun` and `scripts/iosrun` to launch the application once built. `iosrun` may need tweaking for your installed simulator.

## Building on Other Platforms

Not supported yet, but coming soon. You can try playing around with the `scripts/linuxbuild` and `linuxrun` if you want to, though.

### Android (experimental)

`scripts/androidbuild` cross-compiles the `SilveranAndroidBridge` package (`AndroidApp/swift`) with the Swift SDK for Android, generates Kotlin-callable JNI bindings via swift-java's jextract plugin, stages the `.so` set into jniLibs, and assembles the debug APK. It needs a swift.org toolchain with the matching `swift sdk install` Android bundle (versions must match exactly; the Xcode toolchain cannot cross-compile), an Android SDK/NDK (default location `~/Library/Android/sdk`, override with `ANDROID_HOME`), and a host JDK 17+. Use `--swift-only` or `--apk-only` for partial builds.

`scripts/androidrun` installs and launches the built APK, booting the first available emulator AVD if no device is connected (override with `SILVERAN_ANDROID_AVD`, or plug in a device with USB debugging enabled).

## SourceKit-LSP Completion

If you are using SourceKit-LSP for code completion, run `scripts/initcompletion` once from the repo root; it builds `SilveranAppleKit` for macOS and the iOS simulator so the LSP has indexes for both.

## Coding Style & Naming Conventions

Follow standard Swift design guidelines for naming and spacing. Keep SwiftUI view files small and favor breakout views when deep nesting occurs. Use `scripts/format` to format all files before commit, and obey its decisions (consistency is better than personal preference).
