# Contributing

## Project Structure & Module Organization

The repository is broken up as follows:

- `XCodeWrapper/` contains the entry point stub and assets for the iOS/macOS app (SwiftUI). This stub immediately calls into `SilveranKit/`, which is where everything is implemented.
- `SilveranKit/` contains the implementation of all apps.

In theory, `XCodeWrapper/` and `SilveranKit/` could be merged into one package for the iOS/macOS app, but technical limitations prevent it for now. SourceKit-LSP only supports SPM packages, and Xcode wants a .xcodeproj for iOS apps. This limitation doesn't affect the other apps.

## Building on macOS

### Preparation

- Run `git submodule update --init` to checkout `extern/foliate-js`
- Install `xcodegen` and `xcbeautify` from Homebrew.
- Install Xcode CLI Tools and accept the Xcode license
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

If you are using SourceKit-LSP for code completion, it will require the `Package.resolved` to exist in the package you are editing. This file is not checked in, so you will need to create it in the package you want completion in. For convenience, a script is included to do this. Running `scripts/initcompletion` should enable your LSP to complete code in `SilveranKit`.

## Coding Style & Naming Conventions

Follow standard Swift design guidelines for naming and spacing. Keep SwiftUI view files small and favor breakout views when deep nesting occurs. Use `scripts/format` to format all files before commit, and obey its decisions (consistency is better than personal preference).
