import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @Bindable var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabsContentWidth: CGFloat = 0
    @State private var tabsViewportWidth: CGFloat = 0

    private var tabsOverflow: Bool {
        tabsContentWidth > tabsViewportWidth + 1
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabPill(
                                tab: tab,
                                tabCount: store.tabs.count,
                                isSelected: tab.id == store.selectedTabID,
                                canClose: store.tabs.count > 1,
                                shortcutHint: index < 8 ? "⌘\(index + 1)" : (index == store.tabs.count - 1 ? "⌘9" : nil)
                            ) {
                                store.selectTab(tab.id)
                            } close: {
                                store.closeTab(tab.id)
                            }
                            .id(tab.id)
                            .onMiddleClick {
                                store.closeTab(tab.id)
                            }
                            .onDrag {
                                store.draggingTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: TabDropDelegate(targetID: tab.id, store: store)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: TabBarContentWidthKey.self, value: geo.size.width)
                        }
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.15),
                        value: store.tabs.map(\.id)
                    )
                }
                .scrollIndicators(tabsOverflow ? .visible : .hidden)
                .onChange(of: store.selectedTabID) { _, newID in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabBarViewportWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(TabBarContentWidthKey.self) { tabsContentWidth = $0 }
            .onPreferenceChange(TabBarViewportWidthKey.self) { tabsViewportWidth = $0 }

            Button {
                store.newTab()
            } label: {
                NodaysidleIcon(name: Nodaysidle.Symbol.newTab, size: 13)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Nodaysidle.ColorToken.muted)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
        }
        .padding(.horizontal, 12)
        .frame(height: Nodaysidle.Metric.tabBarHeight)
        .background(Nodaysidle.ColorToken.chrome)
    }
}

// MARK: - Width preferences

private struct TabBarContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabBarViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Drop delegate (live reorder)

/// Reorders live while dragging: entering another pill moves the dragged tab
/// to that position. The NSItemProvider payload is unused — `draggingTabID`
/// carries identity; dropped tabs are inserted immediately before the target.
private struct TabDropDelegate: @MainActor DropDelegate {
    let targetID: UUID
    let store: BrowserStore

    func dropEntered(info: DropInfo) {
        guard let dragging = store.draggingTabID, dragging != targetID else { return }
        store.moveTab(dragging, to: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingTabID = nil
        return true
    }
}

// MARK: - Tab pill

private struct TabPill: View {
    let tab: BrowserTab
    let tabCount: Int
    let isSelected: Bool
    let canClose: Bool
    let shortcutHint: String?
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var pillMaxWidth: CGFloat {
        if tabCount > 12 { return 90 }
        if tabCount > 8 { return 115 }
        if tabCount > 5 { return 135 }
        return 160
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if tab.isLoading && isSelected {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }

                    Text(tab.title)
                        .lineLimit(1)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Nodaysidle.ColorToken.text : Nodaysidle.ColorToken.muted)
                        .frame(maxWidth: pillMaxWidth)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tabAccessibilityLabel)
            .accessibilityAddTraits(.isButton)

            if canClose && (isSelected || hovering) {
                Button(action: close) {
                    NodaysidleIcon(name: Nodaysidle.Symbol.closeTab, size: 9)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Nodaysidle.ColorToken.quiet)
                .help("Close Tab")
                .accessibilityLabel("Close tab \(tab.title)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(isSelected ? Nodaysidle.ColorToken.surface : Color.clear)
        .overlay(
            Capsule()
                .stroke(isSelected ? Nodaysidle.ColorToken.lineStrong : Color.clear, lineWidth: 1)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .help(tabTooltip)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Select") { select() }
        .accessibilityAction(named: "Close") { if canClose { close() } }
    }

    private var tabTooltip: String {
        if let shortcutHint {
            return "\(tab.title) (\(shortcutHint))"
        }
        return tab.title
    }

    private var tabAccessibilityLabel: String {
        var label = "Tab: \(tab.title)"
        if let shortcutHint { label += ", \(shortcutHint)" }
        if isSelected { label += ", active" }
        if tab.isLoading && isSelected { label += ", loading" }
        return label
    }
}
