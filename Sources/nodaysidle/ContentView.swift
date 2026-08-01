import SwiftUI

struct ContentView: View {
    @Bindable var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store)

            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)

            ToolbarView(store: store)

            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)

            ZStack {
                ForEach(store.tabs) { tab in
                    // Lazy hydration: only create the WKWebView on first
                    // selection. Once hydrated the view stays alive in the
                    // ZStack to preserve back-forward state and scroll position.
                    if store.hydratedTabIDs.contains(tab.id) {
                        TabContentView(store: store, tab: tab)
                        .opacity(tab.id == store.selectedTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == store.selectedTabID)
                        .accessibilityHidden(tab.id != store.selectedTabID)
                    }
                }

                if let feedback = store.zoomFeedback {
                    ZoomFeedbackHUD(text: feedback)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(1)
                }

                if store.showTabSwitcher {
                    Color.black
                        .opacity(0.32)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)

                    TabSwitcherView(store: store)
                        .zIndex(2)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Nodaysidle.ColorToken.void)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: store.zoomFeedback
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: store.showTabSwitcher
            )
            .onChange(of: store.zoomFeedback) { _, newValue in
                guard newValue != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    if store.zoomFeedback == newValue {
                        store.clearZoomFeedback()
                    }
                }
            }
        }
        .background(Nodaysidle.ColorToken.void)
        .preferredColorScheme(.dark)
        .focusedSceneValue(\.canCloseTab, store.canCloseTab)
        .focusedSceneValue(\.canUndoCloseTab, store.canUndoCloseTab)
        .focusedSceneValue(\.tabCount, store.tabs.count)
        .focusedSceneValue(\.selectedTabIsHome, store.selectedTab?.isHome == true)
        .task {
            _ = await store.syncSecureLibraryIfConfigured()
        }
    }
}

private struct TabContentView: View {
    @Bindable var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        ZStack {
            if tab.url != nil {
                TabPageView(store: store, tabID: tab.id)
                    .opacity(tab.isHome ? 0 : 1)
                    .allowsHitTesting(!tab.isHome)
                    .accessibilityHidden(tab.isHome)
            }

            if tab.isHome {
                NewTabView(store: store, tabID: tab.id)
            }
        }
    }
}

// MARK: - Zoom HUD

private struct ZoomFeedbackHUD: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Nodaysidle.ColorToken.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Nodaysidle.ColorToken.elevated)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Nodaysidle.ColorToken.lineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .accessibilityLabel("Zoom \(text)")
    }
}
