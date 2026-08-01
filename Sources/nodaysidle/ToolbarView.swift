import SwiftUI

struct ToolbarView: View {
    @Bindable var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addressText = ""
    @State private var showingClearSessionConfirmation = false
    @State private var librarySection: BrowserLibrarySection?
    @State private var showingWebsiteDataConfirmation = false
    @State private var websiteDataNotice: String?
    @State private var isClearingWebsiteData = false
    @State private var showingSecureSync = false
    @State private var secureSyncNotice: String?
    @FocusState private var addressFieldFocused: Bool

    private var selected: BrowserTab? { store.selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                NodaysidleGhostButton(
                    symbol: Nodaysidle.Symbol.home,
                    helpText: "Home",
                    accessibilityLabel: "Go Home",
                    disabled: selected?.isHome == true,
                    action: store.goHome
                )

                NodaysidleGhostButton(
                    symbol: Nodaysidle.Symbol.back,
                    helpText: "Back",
                    accessibilityLabel: "Go Back",
                    disabled: selected?.canGoBack != true,
                    action: store.goBack
                )

                NodaysidleGhostButton(
                    symbol: Nodaysidle.Symbol.forward,
                    helpText: "Forward",
                    accessibilityLabel: "Go Forward",
                    disabled: selected?.canGoForward != true,
                    action: store.goForward
                )

                NodaysidleGhostButton(
                    symbol: reloadSymbol,
                    helpText: selected?.isLoading == true ? "Stop" : "Reload",
                    accessibilityLabel: selected?.isLoading == true ? "Stop page load" : "Reload page",
                    disabled: selected?.isHome == true,
                    action: store.reload
                )

                AddressField(
                    text: $addressText,
                    isSecure: isHTTPS,
                    isInsecure: isInsecure,
                    securityHint: securityDescription,
                    focused: $addressFieldFocused
                ) {
                    submitAddress()
                } onEscape: {
                    syncAddressFromTab()
                    addressFieldFocused = false
                }
                .frame(maxWidth: .infinity)

                Menu {
                    Section("Website Appearance") {
                        Label("Follows each website", systemImage: "checkmark")
                    }

                    Section("Search Engine") {
                        Picker("Default Search Engine", selection: $store.searchEngine) {
                            Text("DuckDuckGo").tag(SearchEngine.duckduckgo)
                            Text("Google").tag(SearchEngine.google)
                            Text("Brave").tag(SearchEngine.brave)
                        }
                        .help("Choose the default search engine for queries")
                    }

                    Section("Library") {
                        Button(
                            store.isSelectedPageBookmarked
                                ? "Remove Bookmark"
                                : "Bookmark This Page"
                        ) {
                            store.toggleBookmarkForSelectedPage()
                        }
                        .disabled(!store.canBookmarkSelectedPage)

                        Button("Bookmarks…") {
                            librarySection = .bookmarks
                        }

                        Button("History…") {
                            librarySection = .history
                        }
                    }

                    Section("Secure Sync") {
                        Label(store.secureSyncStatus.label, systemImage: store.secureSyncStatus.symbolName)

                        Button(
                            store.secureSyncIsConfigured
                                ? "Manage Secure Sync…"
                                : "Set Up Secure Sync…"
                        ) {
                            showingSecureSync = true
                        }

                        if store.secureSyncIsConfigured && store.secureSyncIsUnlocked {
                            Button("Sync Now") {
                                syncSecureLibrary()
                            }
                            .disabled(store.secureSyncIsSyncing)
                        }
                    }

                    Section("Session") {
                        Button("Forget Saved Tabs", role: .destructive) {
                            showingClearSessionConfirmation = true
                        }
                    }

                    Section("Privacy") {
                        Button(websiteDataButtonTitle, role: .destructive) {
                            showingWebsiteDataConfirmation = true
                        }
                        .disabled(store.selectedPageHost == nil || isClearingWebsiteData)
                        .help("Clear cookies, cache, and local storage for the current website")
                    }

                    Divider()
                    Button("About nodaysidle") {
                        NSApplication.shared.orderFrontStandardAboutPanel(nil)
                    }
                } label: {
                    NodaysidleIcon(name: Nodaysidle.Symbol.menu)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(Nodaysidle.ColorToken.muted)
                .help("Settings Menu")
                .accessibilityLabel("Settings menu")

                // Hidden shortcut targets for focus and reload
                Button(action: { addressFieldFocused = true }) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("l", modifiers: [.command])
                    .accessibilityHidden(true)

                Button(action: store.reload) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: Nodaysidle.Metric.toolbarHeight)
            .accessibilityElement(children: .contain)
            .accessibilityValue(loadingAccessibilityValue)

            // Sleek Page Load Progress Indicator
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(height: 2)

                if let selected, selected.isLoading, selected.estimatedProgress < 1.0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Nodaysidle.ColorToken.accent)
                            .frame(width: geo.size.width * CGFloat(selected.estimatedProgress))
                            .animation(
                                reduceMotion ? nil : .linear(duration: 0.1),
                                value: selected.estimatedProgress
                            )
                    }
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
        .background(Nodaysidle.ColorToken.chrome)
        .sheet(item: $librarySection) { section in
            BrowserLibraryView(store: store, section: section)
        }
        .sheet(isPresented: $showingSecureSync) {
            SecureSyncView(store: store)
        }
        .confirmationDialog(
            "Forget Saved Tabs?",
            isPresented: $showingClearSessionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Saved Tabs", role: .destructive) {
                store.clearSavedSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes saved tab URLs from this Mac. Open tabs stay open until you close them.")
        }
        .confirmationDialog(
            "Clear Website Data?",
            isPresented: $showingWebsiteDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Website Data", role: .destructive) {
                clearWebsiteData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(websiteDataConfirmationMessage)
        }
        .alert(
            "Website Data",
            isPresented: Binding(
                get: { websiteDataNotice != nil },
                set: { if !$0 { websiteDataNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                websiteDataNotice = nil
            }
        } message: {
            Text(websiteDataNotice ?? "")
        }
        .alert(
            "Secure Sync",
            isPresented: Binding(
                get: { secureSyncNotice != nil },
                set: { if !$0 { secureSyncNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                secureSyncNotice = nil
            }
        } message: {
            Text(secureSyncNotice ?? "")
        }
        .onChange(of: store.selectedTabID) { _, _ in
            addressFieldFocused = false
            syncAddressFromTab()
        }
        .onAppear { syncAddressFromTab() }
        .onChange(of: selected?.url?.absoluteString) { _, _ in
            // Don't stomp in-progress typing when a load/redirect lands;
            // tab switches (above) always resync.
            if !addressFieldFocused { syncAddressFromTab() }
        }
        .onChange(of: selected?.isHome) { _, _ in
            syncAddressFromTab()
        }
        .onChange(of: store.showFindBar) { _, isPresented in
            if isPresented {
                addressFieldFocused = false
            }
        }
    }

    private var reloadSymbol: String {
        selected?.isLoading == true ? Nodaysidle.Symbol.stop : Nodaysidle.Symbol.reload
    }

    private var loadingAccessibilityValue: String {
        guard let selected, selected.isLoading else { return "" }
        let percent = Int(selected.estimatedProgress * 100)
        return "Loading page, \(percent) percent"
    }

    private var isHTTPS: Bool {
        selected?.url?.scheme?.lowercased() == "https"
    }

    /// Any non-HTTPS loaded page (http, file, custom schemes).
    private var isInsecure: Bool {
        guard let tab = selected, !tab.isHome, let scheme = tab.url?.scheme?.lowercased() else {
            return false
        }
        return scheme != "https"
    }

    private var securityDescription: String {
        if isHTTPS { return "Secure connection" }
        if isInsecure { return "Not secure" }
        return ""
    }

    private var websiteDataButtonTitle: String {
        guard let host = store.selectedPageHost else {
            return "Clear Website Data"
        }
        return "Clear \(host) Website Data"
    }

    private var websiteDataConfirmationMessage: String {
        guard let host = store.selectedPageHost else {
            return "No website is selected."
        }
        return "Removes cookies, cache, and local storage for \(host). This may sign you out of the website."
    }

    private func syncAddressFromTab() {
        guard let tab = selected else {
            addressText = ""
            return
        }
        if tab.isHome {
            addressText = ""
        } else {
            addressText = tab.url?.absoluteString ?? ""
        }
    }

    private func submitAddress() {
        store.navigateSelected(to: addressText)
        addressFieldFocused = false
        DispatchQueue.main.async {
            store.focusSelectedWebView()
        }
    }

    private func clearWebsiteData() {
        guard !isClearingWebsiteData else { return }
        isClearingWebsiteData = true
        Task { @MainActor in
            let result = await store.clearWebsiteDataForSelectedSite()
            isClearingWebsiteData = false
            switch result {
            case .noSite:
                websiteDataNotice = "No website is selected."
            case .noData:
                websiteDataNotice = "No stored website data was found for this site."
            case .cleared:
                websiteDataNotice = "Website data was cleared. You may need to sign in again."
            }
        }
    }

    private func syncSecureLibrary() {
        Task { @MainActor in
            let result = await store.syncSecureLibrary()
            if case let .failed(message) = result {
                secureSyncNotice = message
            }
        }
    }
}

// MARK: - Address field

private struct AddressField: View {
    @Binding var text: String
    var isSecure: Bool
    var isInsecure: Bool
    var securityHint: String
    var focused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            if text.isEmpty {
                NodaysidleIcon(name: Nodaysidle.Symbol.search, size: 13)
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
                    .accessibilityHidden(true)
            } else if isSecure {
                NodaysidleIcon(name: Nodaysidle.Symbol.lock, size: 12)
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
                    .accessibilityHidden(true)
            } else if isInsecure {
                NodaysidleIcon(name: "exclamationmark.triangle", size: 12)
                    .foregroundStyle(Nodaysidle.ColorToken.danger)
                    .accessibilityHidden(true)
            }

            // The TextField stays mounted even when showing the domain-only
            // display, so FocusState (⌘L, click) can always take effect.
            ZStack(alignment: .leading) {
                TextField(
                    "",
                    text: $text,
                    prompt: Text(Nodaysidle.Copy.searchPlaceholder)
                        .foregroundStyle(Nodaysidle.ColorToken.muted)
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.text)
                    .focused(focused)
                    .onSubmit(onCommit)
                    .onKeyPress(.escape) {
                        onEscape()
                        return .handled
                    }
                    .onChange(of: focused.wrappedValue) { _, isFocused in
                        if isFocused {
                            DispatchQueue.main.async {
                                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                            }
                        }
                    }
                    .opacity(focused.wrappedValue ? 1 : 0)
                    .allowsHitTesting(focused.wrappedValue)
                    .accessibilityLabel("Address bar")
                    .accessibilityHint(securityHint)

                if !focused.wrappedValue {
                    // Display mode — domain-emphasized (host only, Safari-style)
                    Button(action: { focused.wrappedValue = true }) {
                        Text(displayText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? Nodaysidle.ColorToken.muted : Nodaysidle.ColorToken.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Address bar — \(displayText)")
                    .accessibilityHint(displayAccessibilityHint)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Nodaysidle.ColorToken.surface)
        .overlay(
            Capsule()
                .stroke(focused.wrappedValue ? Nodaysidle.ColorToken.accent : Nodaysidle.ColorToken.line, lineWidth: 1)
        )
        .clipShape(Capsule())
        .help(securityHint)
    }

    private var displayAccessibilityHint: String {
        let editHint = "Click or press ⌘L to edit"
        guard !securityHint.isEmpty else { return editHint }
        return "\(securityHint). \(editHint)"
    }

    /// Domain-only display when not editing (Safari-style).
    private var displayText: String {
        if text.isEmpty { return Nodaysidle.Copy.searchPlaceholder }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            return text
        }
        return host
    }
}
