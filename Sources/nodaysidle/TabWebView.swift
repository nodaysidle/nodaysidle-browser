import SwiftUI
import WebKit

struct TabWebView: NSViewRepresentable {
    let tabID: UUID
    @Bindable var store: BrowserStore
    /// Called when the user navigates to a non-web scheme (mailto:, tel:, etc.)
    /// — the wrapper shows a confirmation dialog instead of launching immediately.
    var onExternalURL: ((URL) -> Void)?
    /// Called when a page requests camera or microphone access.
    var onMediaPermissionRequest: ((SitePermissionRequest) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabID: tabID,
            store: store,
            onExternalURL: onExternalURL,
            onMediaPermissionRequest: onMediaPermissionRequest
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = SiteAppearance.makeConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        SiteAppearance.apply(to: webView)
        syncVisibility(of: webView)
        store.register(webView: webView, for: tabID)
        context.coordinator.webView = webView
        context.coordinator.setupObservation(for: webView)

        // Initial load (including session-restored tabs) goes through
        // syncIfNeeded so lastLoaded is recorded and updateNSView does not
        // trigger a duplicate load.
        context.coordinator.syncIfNeeded(webView: webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        SiteAppearance.apply(to: webView)
        syncVisibility(of: webView)
        context.coordinator.syncIfNeeded(webView: webView)
        context.coordinator.syncFindIfNeeded(webView: webView)
        context.coordinator.onExternalURL = onExternalURL
        context.coordinator.onMediaPermissionRequest = onMediaPermissionRequest
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
        coordinator.store.unregister(tabID: coordinator.tabID)
    }

    private func syncVisibility(of webView: WKWebView) {
        let hidden = store.tabs.first(where: { $0.id == tabID })?.isHome == true
        webView.isHidden = hidden
        webView.setAccessibilityHidden(hidden)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let tabID: UUID
        let store: BrowserStore
        var onExternalURL: ((URL) -> Void)?
        var onMediaPermissionRequest: ((SitePermissionRequest) -> Void)?
        weak var webView: WKWebView?
        private var lastLoaded: URL?
        private var stateObservations: [NSKeyValueObservation] = []

        // Find state
        private var lastFindTrigger = 0
        private var lastFindQuery = ""

        init(
            tabID: UUID,
            store: BrowserStore,
            onExternalURL: ((URL) -> Void)?,
            onMediaPermissionRequest: ((SitePermissionRequest) -> Void)?
        ) {
            self.tabID = tabID
            self.store = store
            self.onExternalURL = onExternalURL
            self.onMediaPermissionRequest = onMediaPermissionRequest
        }

        func setupObservation(for webView: WKWebView) {
            cleanup()
            stateObservations = [
                observe(\.url, on: webView),
                observe(\.title, on: webView),
                observe(\.isLoading, on: webView),
                observe(\.canGoBack, on: webView),
                observe(\.canGoForward, on: webView),
                observe(\.estimatedProgress, on: webView),
            ]
        }

        private func observe<Value>(
            _ keyPath: KeyPath<WKWebView, Value>,
            on webView: WKWebView
        ) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.initial, .new]) { [weak self] observedWebView, _ in
                Task { @MainActor [weak self, weak observedWebView] in
                    guard let self, let observedWebView else { return }
                    self.store.webViewDidUpdate(tabID: self.tabID, webView: observedWebView)
                }
            }
        }

        func cleanup() {
            stateObservations.forEach { $0.invalidate() }
            stateObservations.removeAll()
        }

        deinit {
            stateObservations.forEach { $0.invalidate() }
        }

        // MARK: - Load sync

        func syncIfNeeded(webView: WKWebView) {
            guard let tab = store.tabs.first(where: { $0.id == tabID }),
                  let url = tab.url,
                  url != lastLoaded
            else { return }
            lastLoaded = url
            // Store-initiated navigations already called load(); only load
            // here when the web view isn't on (or already heading to) this
            // URL — e.g. session-restored tabs. Avoids double-loading every
            // address-bar navigation.
            if webView.url != url {
                webView.load(BrowserStore.navigationRequest(for: url))
            }
        }

        // MARK: - Find-in-page

        func syncFindIfNeeded(webView: WKWebView) {
            guard store.showFindBar,
                  store.selectedTabID == tabID,
                  store.findTrigger != lastFindTrigger,
                  !store.findQuery.isEmpty
            else { return }

            lastFindTrigger = store.findTrigger
            let query = store.findQuery
            let queryChanged = query != lastFindQuery
            let backwards = store.findBackwards
            lastFindQuery = query

            let config = WKFindConfiguration()
            config.backwards = backwards
            config.wraps = true
            config.caseSensitive = false

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await webView.find(query, configuration: config)
                    guard self.store.findQuery == query else { return }

                    if queryChanged {
                        // Fresh search — count all matches.
                        let count = await self.countMatches(in: webView, query: query)
                        guard self.store.findQuery == query else { return }
                        self.store.findMatchCount = count
                        self.store.findMatchIndex = result.matchFound ? 1 : 0
                    } else if result.matchFound {
                        // Navigating between existing matches.
                        if backwards {
                            self.store.findMatchIndex = self.store.findMatchCount > 0
                                ? ((self.store.findMatchIndex - 2 + self.store.findMatchCount) % self.store.findMatchCount) + 1
                                : 0
                        } else {
                            self.store.findMatchIndex = self.store.findMatchCount > 0
                                ? (self.store.findMatchIndex % self.store.findMatchCount) + 1
                                : 0
                        }
                    }
                } catch {
                    if self.store.findQuery == query {
                        self.store.findMatchCount = 0
                        self.store.findMatchIndex = 0
                    }
                }
            }
        }

        /// Counts occurrences of `query` in visible text nodes (including Shadow DOM) via recursive walker.
        /// Returns the match count or -1 on error.
        private func countMatches(in webView: WKWebView, query: String) async -> Int {
            guard let json = try? JSONEncoder().encode(query),
                  let jsString = String(data: json, encoding: .utf8)
            else { return 0 }

            let js = """
            (function(){
              var q=\(jsString);
              if(!q)return 0;
              try {
                var c = 0;
                var r = new RegExp(q.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
                function walk(node) {
                  if (!node) return;
                  if (node.nodeType === Node.TEXT_NODE) {
                    var parent = node.parentElement;
                    if (parent && /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(parent.tagName)) return;
                    var m = node.textContent.match(r);
                    if (m) c += m.length;
                  } else {
                    if (node.childNodes) {
                      for (var i = 0; i < node.childNodes.length; i++) {
                        walk(node.childNodes[i]);
                      }
                    }
                    if (node.shadowRoot) {
                      walk(node.shadowRoot);
                    }
                  }
                }
                walk(document.body);
                return c;
              } catch(e) { return -1; }
            })()
            """

            do {
                let result = try await webView.evaluateJavaScript(js)
                return (result as? Int) ?? 0
            } catch {
                return -1
            }
        }

        // MARK: - Navigation delegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.clearNavigationError(tabID: tabID)
            store.webViewDidUpdate(tabID: tabID, webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastLoaded = webView.url
            store.clearNavigationError(tabID: tabID)
            store.webViewDidUpdate(tabID: tabID, webView: webView)
            store.recordHistory(tabID: tabID, url: webView.url, title: webView.title)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !Self.isNavigationCancellation(error) else {
                store.webViewDidUpdate(tabID: tabID, webView: webView)
                return
            }
            store.reportNavigationError(tabID: tabID, message: Self.userFacingMessage(for: error))
            store.webViewDidUpdate(tabID: tabID, webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !Self.isNavigationCancellation(error) else {
                store.webViewDidUpdate(tabID: tabID, webView: webView)
                return
            }
            store.reportNavigationError(tabID: tabID, message: Self.userFacingMessage(for: error))
            store.webViewDidUpdate(tabID: tabID, webView: webView)
        }

        private static func isNavigationCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }

        private static func userFacingMessage(for error: Error) -> String {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet:
                    return "Check your internet connection and try again."
                case NSURLErrorTimedOut:
                    return "The request timed out. Try again."
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                    return "The server could not be found. Check the address and try again."
                case NSURLErrorCannotConnectToHost:
                    return "Could not connect to the server. Try again."
                default:
                    break
                }
            }
            return error.localizedDescription
        }

        /// Schemes WKWebView renders itself; anything else (mailto:, tel:,
        /// facetime:, custom app schemes) triggers a confirmation dialog.
        private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  !Self.webSchemes.contains(scheme)
            else { return .allow }
            // Defer to the view layer for confirmation; the alert calls
            // NSWorkspace.open or cancels.
            onExternalURL?(url)
            return .cancel
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            let kind: SitePermissionKind
            switch type {
            case .camera:
                kind = .camera
            case .microphone:
                kind = .microphone
            case .cameraAndMicrophone:
                kind = .cameraAndMicrophone
            @unknown default:
                decisionHandler(.prompt)
                return
            }

            let request = SitePermissionRequest(
                host: origin.host,
                kind: kind,
                decisionHandler: decisionHandler
            )
            if let onMediaPermissionRequest {
                onMediaPermissionRequest(request)
            } else {
                decisionHandler(.prompt)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Preserve the originating page by honoring new-window requests as tabs.
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
                    store.newTab(opening: url)
                } else {
                    store.newTab(makeActive: true)
                }
            }
            return nil
        }
    }
}
