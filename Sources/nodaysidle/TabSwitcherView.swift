import SwiftUI

struct TabSwitcherView: View {
    @Bindable var store: BrowserStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NodaysidleIcon(name: Nodaysidle.Symbol.search, size: 13)
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
                    .accessibilityHidden(true)

                TextField("Search tabs", text: $store.tabSwitcherQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.text)
                    .focused($searchFocused)
                    .onSubmit(selectFirstResult)
                    .onKeyPress(.escape) {
                        store.dismissTabSwitcher()
                        return .handled
                    }
                    .accessibilityLabel("Search tabs")

                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Nodaysidle.ColorToken.surface)

            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)

            if store.tabSwitcherResults.isEmpty {
                VStack(spacing: 8) {
                    Text("No matching tabs")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.text)
                    Text("Try a tab title or website address.")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.tabSwitcherResults) { tab in
                            Button {
                                store.selectTabFromSwitcher(tab.id)
                            } label: {
                                HStack(spacing: 10) {
                                    NodaysidleIcon(
                                        name: tab.isHome ? "house" : "globe",
                                        size: 12
                                    )
                                    .foregroundStyle(
                                        tab.id == store.selectedTabID
                                            ? Nodaysidle.ColorToken.accent
                                            : Nodaysidle.ColorToken.quiet
                                    )
                                    .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title)
                                            .lineLimit(1)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Nodaysidle.ColorToken.text)
                                        Text(tab.url?.host ?? "New Tab")
                                            .lineLimit(1)
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundStyle(Nodaysidle.ColorToken.muted)
                                    }

                                    Spacer(minLength: 0)

                                    if tab.id == store.selectedTabID {
                                        NodaysidleIcon(name: "checkmark", size: 11)
                                            .foregroundStyle(Nodaysidle.ColorToken.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    tab.id == store.selectedTabID
                                        ? Nodaysidle.ColorToken.surface
                                        : Nodaysidle.ColorToken.elevated.opacity(0.35)
                                )
                                .clipShape(.rect(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Switch to \(tab.title)")
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(width: 520, height: 360)
        .background(Nodaysidle.ColorToken.elevated)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Nodaysidle.ColorToken.lineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab switcher")
        .task {
            await Task.yield()
            searchFocused = true
        }
    }

    private func selectFirstResult() {
        guard let first = store.tabSwitcherResults.first else { return }
        store.selectTabFromSwitcher(first.id)
    }
}
