# Contributing

## Project Structure & Module Organization

The repository is one SPM package (manifest at the repo root, sources nested under `SilveranKit/`) plus thin app shells:

- `Package.swift` defines the products: `SilveranKit` (portable core, no Apple frameworks), `SilveranAppleKit` (all iOS/macOS/tvOS/watchOS code, one target with platform-guarded folders), and the `SilveranContentServer` / `SilveranReadaloud` satellites (injected via `SilveranEnvironment`).
- `SilveranKit/Sources/{Kit,AppleKit,ContentServer,Readaloud}` hold the target sources; `SilveranKit/Tests/` the tests.
- `XCodeWrapper/` contains the entry point stub, assets, and `project.yml` for the Apple apps. The stub builds a `SilveranEnvironment` (injecting the satellites its platform links) and calls the per-platform entry point in `SilveranAppleKit`.
- `LinuxApp/` is the Linux app shell: its own package with a path dependency on the root package.

The manifest must live at the repo root because SwiftPM resolves URL dependencies against the repository root; external consumers depend on this repo and import `SilveranAppleKit` (and optionally the satellites).

## Building on macOS

### Preparation

- Run `git submodule update --init` to checkout `extern/foliate-js`
- Install `xcodegen` and `xcbeautify` from Homebrew.
- Install Xcode CLI Tools and accept the Xcode license
- Copy `XCodeWrapper/Configs/Local.example.xcconfig` to `XCodeWrapper/Configs/Local.xcconfig`.
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

## SourceKit-LSP Completion

If you are using SourceKit-LSP for code completion, run `scripts/initcompletion` once from the repo root; it builds `SilveranAppleKit` for macOS and the iOS simulator so the LSP has indexes for both.

## Coding Style & Naming Conventions

Follow standard Swift design guidelines for naming and spacing. Keep SwiftUI view files small and favor breakout views when deep nesting occurs. Use `scripts/format` to format all files before commit, and obey its decisions (consistency is better than personal preference).
