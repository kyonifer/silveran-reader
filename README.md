# Silveran Reader

A book reading app for ebooks, audiobooks, and readalong books, with tight [Storyteller](https://gitlab.com/storyteller-platform/storyteller) integration.

## Screenshots

### macOS

![Library](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/mac_library.png)

| Reader | Reader |
|--------|--------|
| ![Book 1](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/mac_book1.png) | ![Book 2](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/mac_book2.png) |

### iOS

| Library | Reader | Reader |
|---------|--------|--------|
| ![Library](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/ios_library.png) | ![Book 1](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/ios_book1.png) | ![Book 2](https://raw.githubusercontent.com/kyonifer/s-r-assets/main/screenshots/ios_book2.png) |

## Design Goals

- First-class support for reading ebooks with synced audio narration (readalong books)
- Native look and feel, especially on desktop (macOS only currently)
- Support full integration into a [storyteller server](https://storyteller-platform.gitlab.io/storyteller/), including progress sync
- Support usage as a standalone desktop app
- Allow a highly customizable reading experience

## Development Goals

- Cross-platform native desktop experience as a primary target
- Re-use existing ecosystem when possible (foliate-js, storyteller)
- Modular approach to enable the suite to grow into more use cases in the future
- Minimum dependencies, in order to enable a portable cross-platform implementation. Reinventing the wheel is preferable to limiting our target platforms.

## Roadmap

Currently the macOS Reader app is the priority (with iOS a close second). However, the hope is to support Linux in the future, with potential plans to expand to Windows in the distant future. I don't read on Windows or Android, so these targets may require an interested contributor.

# Building From Source

See [the contributing documentation](CONTRIBUTING.md) for more information. This project is highly experimental currently, so no pre-built executables are available. This is expected to change once things are more complete.
