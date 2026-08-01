import SwiftUI

// MARK: - Focused values (reliable command-menu state)

extension FocusedValues {
    @Entry var canCloseTab: Bool?
    @Entry var canUndoCloseTab: Bool?
    @Entry var tabCount: Int?
    @Entry var selectedTabIsHome: Bool?
}

// MARK: - App

@main
struct NodaysidleApp: App {
    @State private var store = BrowserStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    store.newTab()
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                TabMenuCommands(store: store)
            }
        }
    }
}

// MARK: - Menu commands (FocusedValue-driven)

/// Menu items that need to react to live state (close, reopen, tab nav,
/// find, zoom). Each reads `@FocusedValue` so SwiftUI re-evaluates
/// `.disabled()` when the key-window view updates its scene values.
private struct TabMenuCommands: View {
    let store: BrowserStore

    @FocusedValue(\.canCloseTab) private var canCloseTab: Bool?
    @FocusedValue(\.canUndoCloseTab) private var canUndoCloseTab: Bool?
    @FocusedValue(\.tabCount) private var tabCount: Int?
    @FocusedValue(\.selectedTabIsHome) private var selectedTabIsHome: Bool?

    var body: some View {
        Group {
            Button("Close Tab") {
                store.closeTab(store.selectedTabID)
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!(canCloseTab ?? false))

            Button("Reopen Closed Tab") {
                store.undoCloseTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!(canUndoCloseTab ?? false))

            Divider()

            Button("Next Tab") {
                store.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Tab") {
                store.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            Button("Search Tabs") {
                store.toggleTabSwitcher()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Divider()

            ForEach(1..<9, id: \.self) { n in
                Button("Tab \(n)") {
                    store.selectTab(at: n - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                .disabled((tabCount ?? 0) < n)
            }

            Button("Last Tab") {
                if let count = tabCount, count > 0 {
                    store.selectTab(at: count - 1)
                }
            }
            .keyboardShortcut("9", modifiers: [.command])
            .disabled((tabCount ?? 0) < 1)

            Divider()

            Button("Find") {
                store.toggleFindBar()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(selectedTabIsHome ?? true)

            Divider()

            Button("Zoom In") {
                store.zoomIn()
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                store.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Actual Size") {
                store.zoomReset()
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}
