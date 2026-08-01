import SwiftUI
import WebKit

/// Wraps TabWebView with find-in-page bar, external-link confirmation,
/// and zoom support. Used by ContentView for non-home tabs.
struct TabPageView: View {
    @Bindable var store: BrowserStore
    let tabID: UUID

    @State private var pendingAlert: TabPageAlert?

    private var tab: BrowserTab? {
        store.tabs.first { $0.id == tabID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Find bar — top of tab content, below toolbar (browser convention).
            if store.showFindBar, store.selectedTabID == tabID {
                FindBar(store: store)
            }

            ZStack {
                TabWebView(
                    tabID: tabID,
                    store: store,
                    onExternalURL: { url in
                        pendingAlert = .external(url)
                    },
                    onMediaPermissionRequest: { request in
                        pendingAlert = .permission(request)
                    }
                )

                if let tab, let error = tab.navigationError {
                    NavigationErrorView(
                        host: tab.url?.host ?? tab.url?.absoluteString ?? "this page",
                        message: error
                    ) {
                        store.retryNavigation(tabID: tabID)
                    }
                }
            }
        }
        .alert(item: $pendingAlert) { alert in
            switch alert {
            case .external(let url):
                return Alert(
                    title: Text("Open External Link"),
                    message: Text("nodaysidle will open \(url.absoluteString) in another application."),
                    primaryButton: .default(Text("Open")) {
                        NSWorkspace.shared.open(url)
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .permission(let request):
                return Alert(
                    title: Text("Website Permission"),
                    message: Text("\(request.host) wants to use your \(request.kind.label)."),
                    primaryButton: .default(Text("Allow")) {
                        request.decisionHandler(.grant)
                    },
                    secondaryButton: .cancel(Text("Deny")) {
                        request.decisionHandler(.deny)
                    }
                )
            }
        }
    }
}

private enum TabPageAlert: Identifiable {
    case external(URL)
    case permission(SitePermissionRequest)

    var id: String {
        switch self {
        case .external(let url):
            return "external:\(url.absoluteString)"
        case .permission(let request):
            return "permission:\(request.id.uuidString)"
        }
    }
}

// MARK: - Navigation error

private struct NavigationErrorView: View {
    let host: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            NodaysidleIcon(name: "exclamationmark.triangle", size: 24)
                .foregroundStyle(Nodaysidle.ColorToken.danger)

            Text("Can't reach \(host)")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)

            Text(message)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Try Again", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Nodaysidle.ColorToken.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Nodaysidle.ColorToken.lineStrong, lineWidth: 1)
                )
                .accessibilityLabel("Try again to load \(host)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Nodaysidle.ColorToken.void)
    }
}

// MARK: - Find bar

/// Inline find bar shown at the top of a web tab. Driven entirely
/// by the `store` find state (⌘F toggles, typed query triggers searches).
private struct FindBar: View {
    @Bindable var store: BrowserStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in page", text: $store.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)
                .focused($focused)
                .onSubmit {
                    if store.findMatchCount != 0 {
                        store.performFind(forward: true)
                    }
                }
                .onKeyPress(.escape) {
                    store.dismissFind()
                    return .handled
                }
                .task(id: store.findQuery) {
                    let query = store.findQuery
                    store.findMatchIndex = 0
                    store.findMatchCount = 0
                    guard !query.isEmpty else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(180))
                    } catch {
                        return
                    }
                    guard store.findQuery == query else { return }
                    store.performFind(forward: true)
                }
                .frame(width: 200)
                .accessibilityLabel("Find in page")

            // Match count. WKWebView.find reports only found/not-found;
            // the coordinator runs a read-only JS TreeWalker to get the count.
            if let status = store.findStatusText {
                Text(status)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(status == "No matches" ? Nodaysidle.ColorToken.danger : Nodaysidle.ColorToken.muted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Find results")
                    .accessibilityValue(status)
            }

            Spacer()

            // Previous / Next
            NodaysidleGhostButton(
                symbol: Nodaysidle.Symbol.findPrev,
                helpText: "Previous match",
                accessibilityLabel: "Previous match",
                disabled: store.findQuery.isEmpty,
                action: { store.performFind(forward: false) }
            )
            NodaysidleGhostButton(
                symbol: Nodaysidle.Symbol.findNext,
                helpText: "Next match",
                accessibilityLabel: "Next match",
                disabled: store.findQuery.isEmpty,
                action: { store.performFind(forward: true) }
            )

            // Dismiss
            Button {
                store.dismissFind()
            } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.muted)
            }
            .buttonStyle(.plain)
            .help("Close find bar")
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Nodaysidle.ColorToken.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)
        }
        .task {
            await Task.yield()
            focused = true
        }
    }
}
