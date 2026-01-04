# Changelog

## [0.1-59] - Unreleased

### Features

- One-click play on iOS and macOS
- New highlighting system with text or background highlighting and four new presets
- Configurable bottom bar on iOS to show preferred tabs
- Author view now uses row-view of authors
- New views for books by tag and narrator
- Progress sync prompt when new server progress is received while reading, with option to keep current location or jump to server position
- Faster navigation with new media overlay manager
- Reworked book details view on iOS

### Bug Fixes

- Progress sync now performed every 3 seconds to match ST clients
- Books in more than one collection now show up in all of them
- Fixed progress sync issues when restoring readaloud from audio
- Fixed progress sync issues when resuming from background
- Apple Watch progress sync now follows other clients (including audio playthrough)
- Settings completely redone
- New robust media overlay playhead handling eliminates race conditions, fixing blank page on chapter switch and flickering between pages during audio playback
- Fixed EPUB3 TOC navigation
- Display multiple narrators and authors
- Fixed bluetooth headset issues
- Switched to ST readaloud icon for consistency
