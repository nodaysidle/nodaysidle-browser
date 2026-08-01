# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native macOS browser — minimal void UI, WebKit engine, no HTML chrome layer. Warm charcoal dark-only theme (`#151518`), SF Symbols, monospaced chrome text. GrapheneOS-inspired: search-only home, no shortcut grid, no telemetry, local-only settings.

## Build & Run

```bash
# Development build
swift build

# Package as .app bundle (ad-hoc signed)
bash Scripts/package_app.sh release

# Install to /Applications
bash Scripts/install-app.sh

# Open the built app
open nodaysidle.app
```

**Requirements:** Swift 6, macOS 14+, Apple Silicon. No CocoaPods/Carthage — SPM only.

`package_app.sh` sources `version.env` (`MARKETING_VERSION`, `BUILD_NUMBER`), runs `Scripts/build_icon.sh`, builds for the host arch, assembles the bundle with a generated Info.plist, and ad-hoc signs (`codesign --sign "-"`). `APP_NAME`, `BUNDLE_ID` (default `com.nodaysidle.browser`), and `MACOS_MIN_VERSION` are overridable via env vars.

**Current non-goals** (per README): extensions, adblock, and browser-profile sync beyond the optional encrypted bookmarks/history vault.

## Architecture

Swift Package with executable target `nodaysidle` in `Sources/nodaysidle/` and focused XCTest coverage in `Tests/nodaysidleTests/`.

### Data Flow

`BrowserStore` (`@Observable`, `@MainActor`) is the single state owner. Created by `NodaysidleApp` (in `nodaysidleApp.swift`) as `@State` and passed down the view tree. Views access it via `@Bindable var store: BrowserStore`. Never create additional store instances.

**Store responsibilities:**
- Tab array + selection (`tabs: [BrowserTab]`, `selectedTabID: UUID`)
- WKWebView registry (`webViews: [UUID: WKWebView]`) — one web view per tab
- Navigation actions (`navigateSelected`, `navigate(tabID:to:)`, `goBack`, `goForward`, `reload`, `goHome`)
- `searchEngine` preference (persisted to `nodaysidle.searchEngine`) — `SearchEngine` enum in `Navigation.swift`: DuckDuckGo (default), Google, Brave
- Session persistence — tab URLs/titles + selected index saved to `nodaysidle.session` (JSON in UserDefaults) on every tab/URL/selection mutation, restored in `init`
- Bookmarks and bounded local history — stored as Codable records in UserDefaults; history is deduplicated by URL and can be cleared from the library view
- Optional encrypted bookmarks/history sync — an authenticated CryptoKit vault in a user-selected shared folder, with the derived key kept in Keychain and local storage remaining the default
- Tab switcher — transient title/URL filtering opened with ⌘K
- Website data controls — WebKit's persistent default store keeps login cookies across relaunches; current-site cookies/cache/local storage can be cleared explicitly
- Undo-close stack (`closedTabs`, max 10) — `undoCloseTab()` restores URL/title/position (⌘⇧T)
- Lazy hydration (`hydratedTabIDs`) — gates WKWebView creation per tab
- Find-in-page state (`findQuery`/`showFindBar`/`findTrigger`/`findMatchIndex`/`findMatchCount`) — debounced in `FindBar`, executed by `TabWebView.Coordinator.syncFindIfNeeded` via `WKWebView.find`, and counted with a read-only JS TreeWalker
- Zoom (`zoomIn`/`zoomOut`/`zoomReset`) via `WKWebView.pageZoom` (0.25–4.0)

The last tab can never be closed (`closeTab` guards `tabs.count > 1`). `goHome` presents the native New Tab surface while preserving the current web view; Back returns to that page without destroying its history or scroll state.

**Tab model** (`BrowserTab`): value type with `id`, `title`, `url?`, stored `isHome`, `isLoading`, `canGoBack`, `canGoForward`, and `estimatedProgress`.

### View Tree

```
ContentView (VStack)
├── TabBarView — horizontal scroll of TabPill capsules + new-tab button
│     (middle-click close, live drag reorder via store.draggingTabID)
├── Separator (1px, ColorToken.line)
├── ToolbarView
│   ├── Ghost buttons: Home, Back, Forward, Reload/Stop
│   ├── AddressField — domain-only display when unfocused (Safari-style);
│   │     TextField stays mounted so ⌘L focus always works; ESC reverts edits
│   └── Settings Menu (library, secure sync, website data/session controls, search engine picker, About)
├── Separator
└── ZStack (tab content — opacity-switched, lazily hydrated)
    └── TabContentView
        ├── NewTabView (when tab.isHome)
        └── TabPageView — preserved behind Home when the tab has a loaded URL;
              wraps TabWebView + FindBar + external-link alert
```

**Lazy hydration:** only tabs in `store.hydratedTabIDs` get views created (selected tab + previously visited). Session-restored background tabs stay cold until first selection. Once hydrated, tabs stay in the ZStack (opacity-switched, `.allowsHitTesting()`) to preserve WKWebView state.

### WKWebView Bridge

`TabWebView` is an `NSViewRepresentable`. Its `Coordinator` is both `WKNavigationDelegate` and `WKUIDelegate`:

- **Observation:** KVO on `url`, `title`, `isLoading`, back/forward availability, and `estimatedProgress` keeps browser chrome synchronized with redirects and SPA navigation
- **Sync:** `syncIfNeeded(webView:)` guards against redundant loads via `lastLoaded` URL tracking
- **Popup handling:** `createWebViewWith` → when `targetFrame == nil`, opens the request in a new app tab (returns `nil`)
- **Navigation policy:** `decidePolicyFor` cancels non-web schemes (anything outside http/https/about/blob/data/file/javascript) and routes them through `onExternalURL` → `TabPageView` shows a confirmation alert before `NSWorkspace.shared.open`
- **Registration:** `makeNSView` calls `store.register(webView:for:)`; `dismantleNSView` calls `store.unregister(tabID:)`

`underPageBackgroundColor` is set via the public WebKit API in `SiteAppearance.apply()`. The app does not use private KVC to disable WebKit background drawing.

### Website Appearance

The app chrome remains dark, but websites control their own appearance. `SiteAppearance` configures the default persistent WebKit data store and a matching under-page loading color without injecting or rewriting page color-scheme metadata.

### Navigation Disambiguation

`NavigationInput.resolve()` (in `Navigation.swift`):
- `http://` / `https://` prefix → direct URL
- Contains space → search engine query
- Exact loopback targets (`localhost`, `*.localhost`, `127.0.0.1`, `[::1]`) → `http://<input>`
- Other dotted hosts and IP addresses → `https://<input>`
- Otherwise → search engine query

### Theme System

`Nodaysidle` enum in `Theme.swift` serves as a namespace for:
- `ColorToken` — static `Color` values (void, chrome, surface, elevated, line, text, muted, quiet, accent, danger)
- `Metric` — layout constants (heights, radii, icon size)
- `Symbol` — SF Symbol name strings

Reusable views: `NodaysidleIcon` (sized SF Symbol), `NodaysidleGhostButton` (icon button with hover highlight, optional help text, disabled state).

**The app chrome is dark-only.** `ColorToken` has no light variants and `ContentView` applies `.preferredColorScheme(.dark)` unconditionally. This does not force websites into dark mode.

### Keyboard Shortcuts

Split across two files:

In `nodaysidleApp.swift` via SwiftUI `commands`:
- `⌘T` — New Tab; `⌘W` — Close Tab (disabled on last tab); `⌘⇧T` — Reopen Closed Tab
- `⌘⇧]` / `⌘⇧[` — Next/Previous Tab; `⌘1`–`⌘9` — jump to tab n
- `⌘F` — Find in page (disabled on home tab)
- `⌘K` — Search tabs
- `⌘=` / `⌘-` / `⌘0` — Zoom in/out/reset

In `ToolbarView.swift` via hidden zero-size buttons with `.keyboardShortcut` (they need access to `@FocusState`):
- `⌘L` — Focus address bar
- `⌘R` — Reload

ESC is handled locally via `.onKeyPress(.escape)`: reverts address-bar edits (ToolbarView) and dismisses the find bar (TabPageView).

## Constraints

- **Never change Package.swift** or build scripts unless explicitly required
- **Dark-only app chrome** — do not attempt to add light mode without a complete token system
- **Monospaced chrome text** — keep `design: .monospaced` on UI chrome
- **SF Symbols only** — no custom icon assets in chrome
- **Do not commit** unless explicitly asked
- The `Sources/Chalk/` path referenced in some docs is stale — actual source is `Sources/nodaysidle/`
