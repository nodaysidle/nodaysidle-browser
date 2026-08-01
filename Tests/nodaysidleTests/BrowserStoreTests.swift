import Foundation
import XCTest
import WebKit
@testable import nodaysidle

@MainActor
final class BrowserStoreTests: XCTestCase {
    func testFreshHomeTabRequestsInitialFocus() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)

            XCTAssertTrue(store.selectedTab?.isHome == true)
            XCTAssertEqual(store.pendingNewTabFocusID, store.selectedTabID)
        }
    }

    func testHomePreservesCurrentPageAndBackReturnsToIt() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)

            store.navigateSelected(to: "example.com")
            let pageURL = store.selectedTab?.url

            store.goHome()
            XCTAssertTrue(store.selectedTab?.isHome == true)
            XCTAssertEqual(store.selectedTab?.url, pageURL)
            XCTAssertTrue(store.selectedTab?.canGoBack == true)
            XCTAssertFalse(store.selectedTab?.isLoading == true)
            XCTAssertEqual(store.pendingNewTabFocusID, store.selectedTabID)

            store.goBack()
            XCTAssertFalse(store.selectedTab?.isHome == true)
            XCTAssertEqual(store.selectedTab?.url, pageURL)
            XCTAssertEqual(store.selectedTab?.title, "example.com")
            XCTAssertNil(store.pendingNewTabFocusID)
        }
    }

    func testSessionRestoresPageTabsAndCleanHomeTabs() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.navigateSelected(to: "example.com")
            store.newTab()

            let restored = BrowserStore(userDefaults: defaults)
            XCTAssertEqual(restored.tabs.count, 2)
            XCTAssertEqual(restored.tabs[0].url?.absoluteString, "https://example.com")
            XCTAssertFalse(restored.tabs[0].isHome)
            XCTAssertTrue(restored.tabs[1].isHome)
            XCTAssertNil(restored.tabs[1].url)
            XCTAssertEqual(restored.selectedTabID, restored.tabs[1].id)
            XCTAssertEqual(restored.pendingNewTabFocusID, restored.selectedTabID)
        }
    }

    func testClosedTabCanBeReopened() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.newTab()
            let closedID = store.selectedTabID

            store.closeTab(closedID)
            XCTAssertEqual(store.tabs.count, 1)
            XCTAssertTrue(store.canUndoCloseTab)

            store.undoCloseTab()
            XCTAssertEqual(store.tabs.count, 2)
            XCTAssertTrue(store.selectedTab?.isHome == true)
        }
    }

    func testMoveTabPlacesSourceBeforeTargetInEitherDirection() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.newTab()
            store.newTab()

            let first = store.tabs[0].id
            let second = store.tabs[1].id
            let third = store.tabs[2].id

            store.moveTab(first, to: third)
            XCTAssertEqual(store.tabs.map(\.id), [second, first, third])

            store.moveTab(third, to: second)
            XCTAssertEqual(store.tabs.map(\.id), [third, second, first])
        }
    }

    func testFindStatusTextDescribesCurrentResult() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            XCTAssertNil(store.findStatusText)

            store.findQuery = "needle"
            XCTAssertEqual(store.findStatusText, "No matches")

            store.findMatchCount = 3
            store.findMatchIndex = 2
            XCTAssertEqual(store.findStatusText, "2 of 3")

            store.findMatchCount = -1
            store.findMatchIndex = 1
            XCTAssertEqual(store.findStatusText, "Match found")
        }
    }

    func testClearSavedSessionRemovesPersistedTabsAndClosedTabHistory() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.navigateSelected(to: "example.com")
            store.newTab()
            store.closeTab(store.selectedTabID)
            XCTAssertTrue(store.canUndoCloseTab)

            store.clearSavedSession()

            XCTAssertFalse(store.canUndoCloseTab)
            XCTAssertFalse(store.tabs.isEmpty)
            let restored = BrowserStore(userDefaults: defaults)
            XCTAssertEqual(restored.tabs.count, 1)
            XCTAssertTrue(restored.selectedTab?.isHome == true)
        }
    }

    func testEmptyWebTitleFallsBackToHost() {
        let url = URL(string: "https://example.com/path")
        XCTAssertEqual(BrowserStore.displayTitle(webTitle: nil, url: url), "example.com")
        XCTAssertEqual(BrowserStore.displayTitle(webTitle: "  ", url: url), "example.com")
        XCTAssertEqual(BrowserStore.displayTitle(webTitle: "Example", url: url), "Example")
    }

    func testNavigationRequestHasBoundedTimeout() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(BrowserStore.navigationRequest(for: url).timeoutInterval, 30)
    }

    func testTabSwitcherFiltersByTitleAndURL() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.navigateSelected(to: "example.com")
            store.newTab(opening: URL(string: "https://openai.com/research")!)
            store.newTab()

            store.tabSwitcherQuery = "research"
            XCTAssertEqual(store.tabSwitcherResults.count, 1)
            XCTAssertEqual(store.tabSwitcherResults.first?.url?.host, "openai.com")

            store.tabSwitcherQuery = "new tab"
            XCTAssertEqual(store.tabSwitcherResults.count, 1)
            XCTAssertTrue(store.tabSwitcherResults.first?.isHome == true)
        }
    }

    func testBookmarksAndHistoryPersistLocallyAndDeduplicateVisits() {
        withIsolatedDefaults { defaults in
            let store = BrowserStore(userDefaults: defaults)
            store.navigateSelected(to: "example.com")
            let tabID = store.selectedTabID
            let url = URL(string: "https://example.com/path")!

            store.toggleBookmarkForSelectedPage()
            XCTAssertTrue(store.isSelectedPageBookmarked)
            XCTAssertEqual(store.bookmarks.count, 1)

            store.recordHistory(tabID: tabID, url: url, title: "Example")
            store.recordHistory(tabID: tabID, url: url, title: "Updated Example")
            XCTAssertEqual(store.history.count, 1)
            XCTAssertEqual(store.history.first?.title, "Updated Example")

            let restored = BrowserStore(userDefaults: defaults)
            XCTAssertEqual(restored.bookmarks, store.bookmarks)
            XCTAssertEqual(restored.history, store.history)

            store.toggleBookmarkForSelectedPage()
            XCTAssertTrue(store.bookmarks.isEmpty)
        }
    }

    func testWebsiteDataConfigurationUsesPersistentStore() {
        let configuration = SiteAppearance.makeConfiguration()
        XCTAssertTrue(configuration.websiteDataStore.isPersistent)
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "nodaysidle.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
