<div align="center">
  <img src="Assets/icon.svg" alt="nodaysidle app logo" width="132" height="132">

  # nodaysidle

  **A quiet, native macOS browser for focused browsing.**

  Minimal chrome. Native WebKit pages. Local-first privacy.

  <p>
    <a href="https://github.com/nodaysidle/nodaysidle-browser/releases"><img src="https://img.shields.io/badge/version-0.1.0-8e8e96?style=flat-square" alt="Version 0.1.0"></a>
    <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-151518?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 or newer"></a>
    <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6"></a>
    <img src="https://img.shields.io/badge/telemetry-none-4c8c6b?style=flat-square" alt="No telemetry">
  </p>
</div>

## What is nodaysidle?

`nodaysidle` is a deliberately small native macOS browser built with SwiftUI and WebKit. It keeps the browser controls close at hand and lets the website own the page experience—without a custom HTML chrome layer, shortcut-heavy start page, or application telemetry.

The visual language is warm charcoal, silver, and quiet motion: a focused surface for everyday browsing that stays out of the way.

## Highlights

- Native SwiftUI browser chrome backed by one `WKWebView` per hydrated tab
- Search-first Home screen with DuckDuckGo, Google, and Brave choices
- Multi-tab browsing with drag reordering, tab restoration, and reopen-closed-tab
- `⌘K` tab search by page title or URL
- `⌘F` find in page and adjustable page zoom
- Local bookmarks and bounded browsing history
- Persistent WebKit website sessions, so login cookies survive relaunches
- Current-site controls for clearing cookies, cache, and local storage
- Explicit camera and microphone permission prompts for websites
- Optional encrypted bookmarks/history sync through a user-selected shared folder
- Native accessibility labels, keyboard focus, and reduced-motion support
- No application telemetry

## Secure Sync

Secure Sync is optional and off by default.

1. Open **Settings → Set Up Secure Sync…**.
2. Choose a folder already synchronized by iCloud Drive, Dropbox, or another trusted file service.
3. Create a passphrase and use the same folder and passphrase on another Mac.

The browser writes one encrypted vault, `.nodaysidle-library.sync`, to the selected folder. The vault uses authenticated AES-GCM encryption with a PBKDF2-SHA256-derived key. The passphrase is never written to the vault; each Mac stores its derived key in macOS Keychain, so it does not need to be entered every launch.

Sync merges bookmarks and history across devices and propagates bookmark removal and history clearing. Tabs, website cookies, local storage, and other browser-profile state remain local to each Mac.

## Install and run

### Requirements

- macOS 14 or newer
- Apple Silicon Mac
- Swift 6 through Xcode or Xcode Command Line Tools

### Run from source

```bash
git clone https://github.com/nodaysidle/nodaysidle-browser.git
cd nodaysidle-browser
swift run nodaysidle
```

### Build an application bundle

```bash
bash Scripts/package_app.sh release
open nodaysidle.app
```

### Install to `/Applications`

```bash
bash Scripts/install-app.sh
```

The installer validates the bundle identifier, preserves an existing installation as a timestamped rollback copy, verifies the ad-hoc signature, and refreshes Launch Services registration.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab | <kbd>⌘T</kbd> |
| Close tab | <kbd>⌘W</kbd> |
| Reopen closed tab | <kbd>⇧⌘T</kbd> |
| Focus address bar | <kbd>⌘L</kbd> |
| Reload or stop | <kbd>⌘R</kbd> |
| Find in page | <kbd>⌘F</kbd> |
| Search tabs | <kbd>⌘K</kbd> |
| Previous / next tab | <kbd>⇧⌘[</kbd> / <kbd>⇧⌘]</kbd> |
| Select tab | <kbd>⌘1</kbd>–<kbd>⌘9</kbd> |
| Zoom in / out | <kbd>⌘+</kbd> / <kbd>⌘−</kbd> |
| Actual size | <kbd>⌘0</kbd> |

## Architecture

The project is a Swift Package Manager executable with a focused XCTest target:

```text
Sources/nodaysidle/
├── BrowserStore.swift       # Main-actor browser state and persistence
├── TabWebView.swift         # WebKit bridge and navigation policy
├── BrowserLibrary.swift     # Bookmarks, history, and permission models/UI
├── SecureSync.swift         # CryptoKit vault, merge logic, and Keychain
├── SecureSyncView.swift     # Opt-in sync settings surface
├── TabSwitcherView.swift    # ⌘K tab palette
└── Theme.swift              # Dark-only visual tokens and controls

Tests/nodaysidleTests/
├── BrowserStoreTests.swift
├── NavigationInputTests.swift
└── SecureSyncTests.swift
```

`BrowserStore` is the single `@Observable @MainActor` state owner. Browser state stays local by default; the secure-sync service receives immutable snapshots and performs encryption, file I/O, and merging away from the UI actor.

## Privacy model

- No analytics, telemetry, or application-owned browsing backend
- Website cookies and login sessions are stored by WebKit's persistent data store on this Mac
- Bookmarks, history, and tab session data use local macOS `UserDefaults`
- Full URLs, including query strings, may be stored locally or inside the encrypted sync vault
- Clearing current-site website data can sign you out of that website
- Secure Sync only writes encrypted library data to a folder you explicitly choose

## Development

Run the complete test suite with:

```bash
swift test
```

The project intentionally stays dependency-light: Swift Package Manager, SwiftUI, WebKit, CryptoKit, and macOS system frameworks.

## Scope

The current release focuses on dependable browsing fundamentals and local-first control. Browser extensions, content blocking, and full browser-profile sync are outside the current scope; Secure Sync is limited to bookmarks and history by design.
