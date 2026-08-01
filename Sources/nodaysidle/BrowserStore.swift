import Foundation
import Observation
import WebKit

@Observable
@MainActor
final class BrowserStore {
    var tabs: [BrowserTab]
    var selectedTabID: UUID
    var searchEngine: SearchEngine = .duckduckgo {
        didSet {
            guard searchEngine != oldValue else { return }
            userDefaults.set(searchEngine.rawValue, forKey: Self.searchEngineKey)
        }
    }
    var bookmarks: [BrowserBookmark]
    var history: [BrowserHistoryEntry]
    var secureSyncFolderURL: URL?
    var secureSyncLastSyncDate: Date?
    var secureSyncIsSyncing = false
    var secureSyncErrorMessage: String?

    /// Transient tab switcher state. The query is never persisted.
    var showTabSwitcher = false
    var tabSwitcherQuery = ""

    /// Tabs whose WKWebView has been created. Prevents eager creation of a
    /// WKWebView for every session-restored tab — only the selected tab (and
    /// any the user visits) gets hydrated.
    var hydratedTabIDs: Set<UUID> = []

    /// Find-in-page state.
    var findQuery = ""
    var showFindBar = false
    var findMatchIndex = 0
    var findMatchCount = 0
    var findBackwards = false
    var findTrigger = 0

    /// Tab currently being dragged in the tab bar (live reorder).
    var draggingTabID: UUID?

    /// When set, the matching home tab should auto-focus its search field once.
    var pendingNewTabFocusID: UUID?

    /// Brief zoom level feedback shown after zoom in/out/reset.
    var zoomFeedback: String?

    // MARK: - Private storage

    private static let searchEngineKey = "nodaysidle.searchEngine"
    private static let sessionKey = "nodaysidle.session"
    private static let bookmarksKey = "nodaysidle.bookmarks"
    private static let historyKey = "nodaysidle.history"
    private static let deletedBookmarksKey = "nodaysidle.deletedBookmarks"
    private static let deletedHistoryKey = "nodaysidle.deletedHistory"
    private static let secureSyncFolderKey = "nodaysidle.secureSync.folder"
    private static let secureSyncLastSyncKey = "nodaysidle.secureSync.lastSync"
    private static let secureSyncDeviceIDKey = "nodaysidle.secureSync.deviceID"
    private static let navigationTimeout: TimeInterval = 30
    private static let maxHistoryEntries = 500

    private let userDefaults: UserDefaults
    private(set) var webViews: [UUID: WKWebView] = [:]
    private var deletedBookmarkURLs: [String: Date]
    private var deletedHistoryURLs: [String: Date]
    private var secureSyncKeyMaterial: SecureSyncKeyMaterial?
    private let secureSyncDeviceID: UUID
    private var secureSyncTask: Task<Void, Never>? = nil

    private struct ClosedTabEntry {
        let url: URL?
        let title: String
        let index: Int
    }

    /// Undo-close stack. Most recent closed tab is last.
    private var closedTabs: [ClosedTabEntry] = []
    private static let maxClosedTabs = 10

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        bookmarks = Self.restoreBookmarks(from: userDefaults)
        history = Self.restoreHistory(from: userDefaults)
        deletedBookmarkURLs = Self.restoreTombstones(forKey: Self.deletedBookmarksKey, from: userDefaults)
        deletedHistoryURLs = Self.restoreTombstones(forKey: Self.deletedHistoryKey, from: userDefaults)
        secureSyncFolderURL = Self.restoreSecureSyncFolder(from: userDefaults)
        secureSyncLastSyncDate = userDefaults.object(forKey: Self.secureSyncLastSyncKey) as? Date
        secureSyncKeyMaterial = try? SecureSyncKeychain.load()
        if let rawDeviceID = userDefaults.string(forKey: Self.secureSyncDeviceIDKey),
           let storedDeviceID = UUID(uuidString: rawDeviceID)
        {
            secureSyncDeviceID = storedDeviceID
        } else {
            let newDeviceID = UUID()
            secureSyncDeviceID = newDeviceID
            userDefaults.set(newDeviceID.uuidString, forKey: Self.secureSyncDeviceIDKey)
        }
        let restored = Self.restoreSession(from: userDefaults)
        tabs = restored.tabs
        selectedTabID = restored.selectedID
        // The selected tab is hydrated immediately — visible on first render.
        tabSelectionOrder.append(restored.selectedID)
        hydratedTabIDs.insert(restored.selectedID)
        if selectedTab?.isHome == true {
            pendingNewTabFocusID = restored.selectedID
        }
        if let raw = userDefaults.string(forKey: Self.searchEngineKey),
           let engine = SearchEngine(rawValue: raw)
        {
            searchEngine = engine
        }
    }

    // MARK: - Computed

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var canCloseTab: Bool {
        tabs.count > 1
    }

    var canUndoCloseTab: Bool {
        !closedTabs.isEmpty
    }

    var findStatusText: String? {
        guard !findQuery.isEmpty else { return nil }
        if findMatchCount > 0 {
            return "\(findMatchIndex) of \(findMatchCount)"
        }
        if findMatchCount < 0, findMatchIndex > 0 {
            return "Match found"
        }
        return "No matches"
    }

    var tabSwitcherResults: [BrowserTab] {
        let query = tabSwitcherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tabs }
        return tabs.filter { tab in
            if tab.title.localizedStandardContains(query) {
                return true
            }
            return tab.url?.absoluteString.localizedStandardContains(query) == true
        }
    }

    var selectedPageURL: URL? {
        guard let tab = selectedTab, !tab.isHome else { return nil }
        return Self.persistentPageURL(tab.url)
    }

    var selectedPageHost: String? {
        selectedPageURL?.host
    }

    var canBookmarkSelectedPage: Bool {
        selectedPageURL != nil
    }

    var isSelectedPageBookmarked: Bool {
        guard let url = selectedPageURL else { return false }
        return bookmarks.contains { $0.url == url }
    }

    var secureSyncIsConfigured: Bool {
        secureSyncFolderURL != nil
    }

    var secureSyncIsUnlocked: Bool {
        secureSyncKeyMaterial != nil
    }

    var secureSyncStatus: SecureSyncStatus {
        if secureSyncIsSyncing { return .syncing }
        guard secureSyncIsConfigured else { return .disabled }
        guard secureSyncKeyMaterial != nil else { return .locked }
        if let secureSyncErrorMessage { return .failed(secureSyncErrorMessage) }
        return .ready
    }

    var secureSyncFolderPath: String? {
        secureSyncFolderURL?.path
    }

    // MARK: - WebView registry

    func register(webView: WKWebView, for tabID: UUID) {
        webViews[tabID] = webView
        SiteAppearance.apply(to: webView)
    }

    func unregister(tabID: UUID) {
        webViews.removeValue(forKey: tabID)
    }

    /// Order of tab selection for LRU tab suspension memory management.
    private var tabSelectionOrder: [UUID] = []
    private static let maxHydratedTabs = 15

    // MARK: - Hydration

    func hydrateTab(_ id: UUID) {
        tabSelectionOrder.removeAll { $0 == id }
        tabSelectionOrder.append(id)
        hydratedTabIDs.insert(id)
        evictExcessHydratedTabsIfNeeded()
    }

    private func evictExcessHydratedTabsIfNeeded() {
        guard hydratedTabIDs.count > Self.maxHydratedTabs else { return }
        for candidate in tabSelectionOrder {
            if candidate != selectedTabID && hydratedTabIDs.contains(candidate) {
                unregister(tabID: candidate)
                hydratedTabIDs.remove(candidate)
                break
            }
        }
    }

    // MARK: - Tab selection

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        hydrateTab(id)
        selectedTabID = id
        syncNavigationState(for: id)
        dismissFind()
        persistSession()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let nextIndex = (index + 1) % tabs.count
            selectTab(tabs[nextIndex].id)
        }
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let prevIndex = (index - 1 + tabs.count) % tabs.count
            selectTab(tabs[prevIndex].id)
        }
    }

    // MARK: - Tab lifecycle

    func newTab(opening url: URL? = nil, makeActive: Bool = true) {
        var tab = BrowserTab.home()
        if let url {
            tab.url = url
            tab.isHome = false
            tab.title = NavigationInput.title(for: url)
            tab.isLoading = true
        }
        tabs.append(tab)
        if makeActive {
            selectedTabID = tab.id
            hydrateTab(tab.id)
            pendingNewTabFocusID = tab.isHome ? tab.id : nil
        }
        persistSession()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        let saved = ClosedTabEntry(
            url: closing.isHome ? nil : closing.url,
            title: closing.isHome ? "New Tab" : closing.title,
            index: index
        )
        unregister(tabID: id)
        hydratedTabIDs.remove(id)
        tabSelectionOrder.removeAll { $0 == id }
        tabs.remove(at: index)
        if selectedTabID == id {
            let fallbackIndex = max(0, index - 1)
            selectedTabID = tabs[fallbackIndex].id
            hydrateTab(selectedTabID)
        }
        closedTabs.append(saved)
        if closedTabs.count > Self.maxClosedTabs {
            closedTabs.removeFirst()
        }
        dismissFind()
        persistSession()
    }

    func undoCloseTab() {
        guard let saved = closedTabs.popLast() else { return }
        var tab = BrowserTab.home()
        if let url = saved.url {
            tab.url = url
            tab.isHome = false
            tab.title = saved.title
        }
        let insertIndex = min(saved.index, tabs.count)
        tabs.insert(tab, at: insertIndex)
        selectTab(tab.id)
        persistSession()
    }

    // MARK: - Tab switcher

    func toggleTabSwitcher() {
        if showTabSwitcher {
            dismissTabSwitcher()
        } else {
            tabSwitcherQuery = ""
            showTabSwitcher = true
        }
    }

    func dismissTabSwitcher() {
        showTabSwitcher = false
        tabSwitcherQuery = ""
    }

    func selectTabFromSwitcher(_ id: UUID) {
        selectTab(id)
        dismissTabSwitcher()
    }

    func moveTab(_ sourceID: UUID, to targetID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
              from != targetIndex
        else { return }
        let tab = tabs.remove(at: from)
        // Drop-enter reorders the dragged tab immediately before the pill
        // being entered, regardless of which direction it moves.
        let destination = tabs.firstIndex(where: { $0.id == targetID }) ?? tabs.count
        tabs.insert(tab, at: destination)
        persistSession()
    }

    // MARK: - Navigation

    func navigateSelected(to input: String) {
        guard let url = NavigationInput.resolve(input, engine: searchEngine) else { return }
        navigate(tabID: selectedTabID, to: url)
    }

    func navigateSelected(to url: URL) {
        navigate(tabID: selectedTabID, to: url)
    }

    /// Navigates a specific tab. Popups/new-window requests must target the
    /// originating tab, not whichever tab happens to be selected.
    func navigate(tabID: UUID, to url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].url = url
        tabs[index].isHome = false
        tabs[index].title = NavigationInput.title(for: url)
        tabs[index].isLoading = true
        tabs[index].estimatedProgress = 0.0
        tabs[index].navigationError = nil
        webViews[tabID]?.load(Self.navigationRequest(for: url))
        persistSession()
    }

    func retryNavigation(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let url = tabs[index].url
        else { return }
        tabs[index].navigationError = nil
        tabs[index].isLoading = true
        tabs[index].estimatedProgress = 0.0
        webViews[tabID]?.load(Self.navigationRequest(for: url))
    }

    func reportNavigationError(tabID: UUID, message: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), !tabs[index].isHome else { return }
        tabs[index].navigationError = message
        tabs[index].isLoading = false
        tabs[index].estimatedProgress = 0.0
    }

    func clearNavigationError(tabID: UUID) {
        updateTab(tabID) { $0.navigationError = nil }
    }

    func goHome() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        guard !tabs[index].isHome else { return }
        webViews[selectedTabID]?.stopLoading()
        tabs[index].isHome = true
        tabs[index].title = "New Tab"
        tabs[index].isLoading = false
        tabs[index].canGoBack = tabs[index].url != nil
        tabs[index].canGoForward = false
        tabs[index].estimatedProgress = 0.0
        tabs[index].navigationError = nil
        pendingNewTabFocusID = selectedTabID
        dismissFind()
        persistSession()
    }

    func goBack() {
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].isHome {
            guard let url = tabs[index].url else { return }
            pendingNewTabFocusID = nil
            tabs[index].isHome = false
            tabs[index].title = Self.displayTitle(webTitle: webViews[selectedTabID]?.title, url: url)
            tabs[index].canGoBack = false
            syncNavigationState(for: selectedTabID)
            persistSession()
            return
        }
        webViews[selectedTabID]?.goBack()
    }

    func goForward() {
        webViews[selectedTabID]?.goForward()
    }

    func reload() {
        if selectedTab?.isHome == true { return }
        if selectedTab?.isLoading == true {
            webViews[selectedTabID]?.stopLoading()
            updateTab(selectedTabID) { $0.isLoading = false }
        } else {
            webViews[selectedTabID]?.reload()
        }
    }

    func focusSelectedWebView() {
        guard let webView = webViews[selectedTabID] else { return }
        webView.window?.makeFirstResponder(webView)
    }

    // MARK: - Zoom

    func zoomIn() {
        guard let webView = webViews[selectedTabID] else { return }
        webView.pageZoom = min(webView.pageZoom + 0.1, 4.0)
        showZoomFeedback(webView.pageZoom)
    }

    func zoomOut() {
        guard let webView = webViews[selectedTabID] else { return }
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.25)
        showZoomFeedback(webView.pageZoom)
    }

    func zoomReset() {
        webViews[selectedTabID]?.pageZoom = 1.0
        showZoomFeedback(1.0)
    }

    private func showZoomFeedback(_ zoom: CGFloat) {
        let percent = Int((zoom * 100).rounded())
        zoomFeedback = percent == 100 ? "Actual Size" : "\(percent)%"
    }

    func clearZoomFeedback() {
        zoomFeedback = nil
    }

    // MARK: - Find-in-page

    func toggleFindBar() {
        guard selectedTab?.isHome == false else { return }
        if showFindBar {
            dismissFind()
        } else {
            showFindBar = true
            findQuery = ""
            findMatchIndex = 0
            findMatchCount = 0
        }
    }

    func performFind(forward: Bool = true) {
        guard !findQuery.isEmpty else { return }
        findBackwards = !forward
        findTrigger += 1
    }

    func dismissFind() {
        showFindBar = false
        findQuery = ""
        findMatchIndex = 0
        findMatchCount = 0
        findBackwards = false
    }

    // MARK: - Bookmarks and history

    func toggleBookmarkForSelectedPage() {
        guard let url = selectedPageURL,
              let tab = selectedTab
        else { return }

        if isSelectedPageBookmarked {
            let deletionDate = Date()
            for bookmark in bookmarks where bookmark.url == url {
                deletedBookmarkURLs[bookmark.url.absoluteString] = deletionDate
            }
            bookmarks.removeAll { $0.url == url }
        } else {
            deletedBookmarkURLs.removeValue(forKey: url.absoluteString)
            bookmarks.insert(
                BrowserBookmark(
                    id: UUID(),
                    title: Self.displayTitle(webTitle: tab.title, url: url),
                    url: url,
                    createdAt: Date()
                ),
                at: 0
            )
        }
        persistBookmarks()
        persistTombstones()
        scheduleSecureSync()
    }

    func removeBookmark(_ id: UUID) {
        let deletionDate = Date()
        for bookmark in bookmarks where bookmark.id == id {
            deletedBookmarkURLs[bookmark.url.absoluteString] = deletionDate
        }
        bookmarks.removeAll { $0.id == id }
        persistBookmarks()
        persistTombstones()
        scheduleSecureSync()
    }

    func clearHistory() {
        let deletionDate = Date()
        for entry in history {
            deletedHistoryURLs[entry.url.absoluteString] = deletionDate
        }
        history.removeAll()
        persistHistory()
        persistTombstones()
        scheduleSecureSync()
    }

    /// Records a completed or client-side navigation without sending data
    /// anywhere. Repeated visits to the same URL are kept as one recent item.
    func recordHistory(tabID: UUID, url: URL?, title: String?) {
        guard tabs.contains(where: { $0.id == tabID }),
              let safeURL = Self.persistentPageURL(url)
        else { return }

        let entryTitle = Self.displayTitle(webTitle: title, url: safeURL)
        let now = Date()
        deletedHistoryURLs.removeValue(forKey: safeURL.absoluteString)
        if let existingIndex = history.firstIndex(where: { $0.url == safeURL }) {
            var existing = history.remove(at: existingIndex)
            existing.title = entryTitle
            existing.visitedAt = now
            history.insert(existing, at: 0)
        } else {
            history.insert(
                BrowserHistoryEntry(
                    id: UUID(),
                    title: entryTitle,
                    url: safeURL,
                    visitedAt: now
                ),
                at: 0
            )
            if history.count > Self.maxHistoryEntries {
                history.removeLast(history.count - Self.maxHistoryEntries)
            }
        }
        persistHistory()
        persistTombstones()
        scheduleSecureSync()
    }

    // MARK: - Secure sync

    func configureSecureSync(folderURL: URL, passphrase: String) async -> SecureSyncOperationResult {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            return recordSecureSyncFailure(.folderUnavailable)
        }
        guard !secureSyncIsSyncing else {
            return recordSecureSyncFailure(.io("A secure sync operation is already in progress."))
        }

        secureSyncTask?.cancel()
        secureSyncIsSyncing = true
        secureSyncErrorMessage = nil
        let snapshot = secureSyncSnapshot()
        let deviceID = secureSyncDeviceID
        let normalizedFolderURL = folderURL.standardizedFileURL

        let outcome: Result<SecureSyncConfiguredVault, SecureSyncError> = await Task.detached(priority: .utility) {
            do {
                let configured = try SecureSyncFileStore.configureAndSynchronize(
                    folderURL: normalizedFolderURL,
                    passphrase: passphrase,
                    snapshot: snapshot,
                    deviceID: deviceID
                )
                return .success(
                    SecureSyncConfiguredVault(
                        document: configured.document,
                        material: configured.material
                    )
                )
            } catch let error as SecureSyncError {
                return .failure(error)
            } catch {
                return .failure(.io("Secure sync could not be completed."))
            }
        }.value

        secureSyncIsSyncing = false
        switch outcome {
        case let .success(configured):
            do {
                try SecureSyncKeychain.save(configured.material)
            } catch let error as SecureSyncError {
                return recordSecureSyncFailure(error)
            } catch {
                return recordSecureSyncFailure(.io("The sync key could not be saved in Keychain."))
            }
            secureSyncFolderURL = normalizedFolderURL
            secureSyncKeyMaterial = configured.material
            secureSyncErrorMessage = nil
            persistSecureSyncSettings()
            applySecureSyncDocument(configured.document)
            secureSyncLastSyncDate = Date()
            userDefaults.set(secureSyncLastSyncDate, forKey: Self.secureSyncLastSyncKey)
            return .synced

        case let .failure(error):
            return recordSecureSyncFailure(error)
        }
    }

    func syncSecureLibraryIfConfigured() async -> SecureSyncOperationResult {
        guard secureSyncIsConfigured else { return .notConfigured }
        guard secureSyncKeyMaterial != nil else { return .locked }
        return await syncSecureLibrary()
    }

    func syncSecureLibrary() async -> SecureSyncOperationResult {
        guard let folderURL = secureSyncFolderURL else { return .notConfigured }
        guard let material = secureSyncKeyMaterial else { return .locked }
        guard !secureSyncIsSyncing else {
            return recordSecureSyncFailure(.io("A secure sync operation is already in progress."))
        }

        secureSyncIsSyncing = true
        secureSyncErrorMessage = nil
        let snapshot = secureSyncSnapshot()
        let deviceID = secureSyncDeviceID

        let outcome: Result<SecureSyncDocument, SecureSyncError> = await Task.detached(priority: .utility) {
            do {
                let document = try SecureSyncFileStore.synchronize(
                    folderURL: folderURL,
                    snapshot: snapshot,
                    material: material,
                    deviceID: deviceID
                )
                return .success(document)
            } catch let error as SecureSyncError {
                return .failure(error)
            } catch {
                return .failure(.io("Secure sync could not be completed."))
            }
        }.value

        secureSyncIsSyncing = false
        switch outcome {
        case let .success(document):
            applySecureSyncDocument(document)
            secureSyncErrorMessage = nil
            secureSyncLastSyncDate = Date()
            userDefaults.set(secureSyncLastSyncDate, forKey: Self.secureSyncLastSyncKey)
            return .synced
        case let .failure(error):
            return recordSecureSyncFailure(error)
        }
    }

    func disableSecureSync() {
        secureSyncTask?.cancel()
        do {
            try SecureSyncKeychain.remove()
        } catch let error as SecureSyncError {
            secureSyncErrorMessage = error.localizedDescription
            return
        } catch {
            secureSyncErrorMessage = "The sync key could not be removed from Keychain."
            return
        }
        secureSyncFolderURL = nil
        secureSyncKeyMaterial = nil
        secureSyncLastSyncDate = nil
        secureSyncErrorMessage = nil
        userDefaults.removeObject(forKey: Self.secureSyncFolderKey)
        userDefaults.removeObject(forKey: Self.secureSyncLastSyncKey)
    }

    /// Clears cookies, cache, and local storage for the selected host only.
    /// The persistent WebKit store remains enabled for all other sites.
    func clearWebsiteDataForSelectedSite() async -> WebsiteDataClearResult {
        guard let host = selectedPageHost else { return .noSite }

        let dataStore = SiteAppearance.persistentWebsiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: dataTypes)
        let matchingRecords = records.filter {
            $0.displayName.localizedCaseInsensitiveCompare(host) == .orderedSame
        }
        guard !matchingRecords.isEmpty else { return .noData }

        await dataStore.removeData(ofTypes: dataTypes, for: matchingRecords)
        webViews[selectedTabID]?.reload()
        return .cleared
    }

    /// Removes the persisted tab session without closing the tabs currently
    /// open in this process. The next launch starts with a clean home tab.
    func clearSavedSession() {
        userDefaults.removeObject(forKey: Self.sessionKey)
        closedTabs.removeAll()
    }

    private func secureSyncSnapshot() -> SecureSyncSnapshot {
        SecureSyncSnapshot(
            bookmarks: bookmarks,
            history: history,
            deletedBookmarkURLs: deletedBookmarkURLs.compactMap { key, date in
                guard let url = URL(string: key) else { return nil }
                return SecureSyncTombstone(url: url, deletedAt: date)
            },
            deletedHistoryURLs: deletedHistoryURLs.compactMap { key, date in
                guard let url = URL(string: key) else { return nil }
                return SecureSyncTombstone(url: url, deletedAt: date)
            }
        )
    }

    private func applySecureSyncDocument(_ document: SecureSyncDocument) {
        bookmarks = document.bookmarks
        history = document.history
        deletedBookmarkURLs = document.deletedBookmarkURLs.reduce(into: [:]) { result, tombstone in
            result[tombstone.url.absoluteString] = tombstone.deletedAt
        }
        deletedHistoryURLs = document.deletedHistoryURLs.reduce(into: [:]) { result, tombstone in
            result[tombstone.url.absoluteString] = tombstone.deletedAt
        }
        persistBookmarks()
        persistHistory()
        persistTombstones()
    }

    private func recordSecureSyncFailure(_ error: SecureSyncError) -> SecureSyncOperationResult {
        let message = error.localizedDescription
        secureSyncErrorMessage = message
        return .failed(message)
    }

    private func scheduleSecureSync() {
        guard secureSyncIsConfigured, secureSyncKeyMaterial != nil else { return }
        secureSyncTask?.cancel()
        secureSyncTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.syncSecureLibrary()
        }
    }

    // MARK: - Tab mutation

    func updateTab(_ id: UUID, _ mutate: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
    }

    func syncNavigationState(for id: UUID) {
        guard let webView = webViews[id], let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard !tabs[index].isHome else { return }
        tabs[index].canGoBack = webView.canGoBack
        tabs[index].canGoForward = webView.canGoForward
        tabs[index].isLoading = webView.isLoading
        tabs[index].estimatedProgress = webView.estimatedProgress
        if let url = webView.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
            tabs[index].url = url
            tabs[index].title = Self.displayTitle(webTitle: webView.title, url: url)
        }
    }

    func webViewDidUpdate(tabID: UUID, webView: WKWebView) {
        guard webViews[tabID] === webView,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[index].isHome
        else { return }

        if tabs[index].isLoading != webView.isLoading {
            tabs[index].isLoading = webView.isLoading
        }
        if tabs[index].canGoBack != webView.canGoBack {
            tabs[index].canGoBack = webView.canGoBack
        }
        if tabs[index].canGoForward != webView.canGoForward {
            tabs[index].canGoForward = webView.canGoForward
        }
        if tabs[index].estimatedProgress != webView.estimatedProgress {
            tabs[index].estimatedProgress = webView.estimatedProgress
        }
        if let url = webView.url,
           !url.absoluteString.isEmpty,
           url.absoluteString != "about:blank"
        {
            let newTitle = Self.displayTitle(webTitle: webView.title, url: url)
            if tabs[index].url != url || tabs[index].title != newTitle {
                tabs[index].url = url
                tabs[index].title = newTitle
                recordHistory(tabID: tabID, url: url, title: newTitle)
                persistSession()
            }
        }
    }

    // MARK: - Session persistence

    private struct SessionTab: Codable {
        var url: String?
        var title: String
    }

    private struct Session: Codable {
        var tabs: [SessionTab]
        var selectedIndex: Int
    }

    private static func restoreSession(from userDefaults: UserDefaults) -> (tabs: [BrowserTab], selectedID: UUID) {
        guard let data = userDefaults.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              !session.tabs.isEmpty
        else {
            let first = BrowserTab.home()
            return ([first], first.id)
        }
        let tabs = session.tabs.map { saved -> BrowserTab in
            var tab = BrowserTab.home()
            if let urlString = saved.url, let url = URL(string: urlString) {
                tab.url = url
                tab.isHome = false
                tab.title = saved.title
            }
            return tab
        }
        let index = min(max(0, session.selectedIndex), tabs.count - 1)
        return (tabs, tabs[index].id)
    }

    private func persistSession() {
        let session = Session(
            tabs: tabs.map {
                SessionTab(
                    url: $0.isHome ? nil : $0.url?.absoluteString,
                    title: $0.isHome ? "New Tab" : $0.title
                )
            },
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID } ?? 0
        )
        if let data = try? JSONEncoder().encode(session) {
            userDefaults.set(data, forKey: Self.sessionKey)
        }
    }

    private static func restoreBookmarks(from userDefaults: UserDefaults) -> [BrowserBookmark] {
        guard let data = userDefaults.data(forKey: bookmarksKey),
              let saved = try? JSONDecoder().decode([BrowserBookmark].self, from: data)
        else { return [] }
        return saved
    }

    private static func restoreHistory(from userDefaults: UserDefaults) -> [BrowserHistoryEntry] {
        guard let data = userDefaults.data(forKey: historyKey),
              let saved = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        else { return [] }
        return Array(saved.prefix(maxHistoryEntries))
    }

    private static func restoreTombstones(forKey key: String, from userDefaults: UserDefaults) -> [String: Date] {
        guard let data = userDefaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([SecureSyncTombstone].self, from: data)
        else { return [:] }
        return saved.reduce(into: [:]) { result, tombstone in
            result[tombstone.url.absoluteString] = tombstone.deletedAt
        }
    }

    private static func restoreSecureSyncFolder(from userDefaults: UserDefaults) -> URL? {
        guard let path = userDefaults.string(forKey: secureSyncFolderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func persistBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        userDefaults.set(data, forKey: Self.bookmarksKey)
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        userDefaults.set(data, forKey: Self.historyKey)
    }

    private func persistTombstones() {
        let bookmarks = deletedBookmarkURLs.compactMap { key, date -> SecureSyncTombstone? in
            guard let url = URL(string: key) else { return nil }
            return SecureSyncTombstone(url: url, deletedAt: date)
        }
        let history = deletedHistoryURLs.compactMap { key, date -> SecureSyncTombstone? in
            guard let url = URL(string: key) else { return nil }
            return SecureSyncTombstone(url: url, deletedAt: date)
        }
        if let bookmarkData = try? JSONEncoder().encode(bookmarks), !bookmarks.isEmpty {
            userDefaults.set(bookmarkData, forKey: Self.deletedBookmarksKey)
        } else {
            userDefaults.removeObject(forKey: Self.deletedBookmarksKey)
        }
        if let historyData = try? JSONEncoder().encode(history), !history.isEmpty {
            userDefaults.set(historyData, forKey: Self.deletedHistoryKey)
        } else {
            userDefaults.removeObject(forKey: Self.deletedHistoryKey)
        }
    }

    private func persistSecureSyncSettings() {
        if let secureSyncFolderURL {
            userDefaults.set(secureSyncFolderURL.path, forKey: Self.secureSyncFolderKey)
        } else {
            userDefaults.removeObject(forKey: Self.secureSyncFolderKey)
        }
        userDefaults.set(secureSyncDeviceID.uuidString, forKey: Self.secureSyncDeviceIDKey)
    }

    private static func persistentPageURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // Never copy URL-embedded credentials into local library records.
        components.user = nil
        components.password = nil
        return components.url
    }

    static func displayTitle(webTitle: String?, url: URL?) -> String {
        let trimmedTitle = webTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? NavigationInput.title(for: url) : trimmedTitle
    }

    static func navigationRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = navigationTimeout
        return request
    }
}
