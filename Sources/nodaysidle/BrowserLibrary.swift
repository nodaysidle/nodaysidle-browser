import SwiftUI
import WebKit

enum BrowserLibrarySection: String, Identifiable {
    case bookmarks
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookmarks:
            return "Bookmarks"
        case .history:
            return "History"
        }
    }

    var subtitle: String {
        switch self {
        case .bookmarks:
            return "Saved locally on this Mac"
        case .history:
            return "Recent pages, newest first"
        }
    }
}

enum WebsiteDataClearResult: Equatable {
    case noSite
    case noData
    case cleared
}

enum SitePermissionKind: String, Identifiable {
    case camera
    case microphone
    case cameraAndMicrophone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera:
            return "camera"
        case .microphone:
            return "microphone"
        case .cameraAndMicrophone:
            return "camera and microphone"
        }
    }
}

struct SitePermissionRequest: Identifiable {
    let id = UUID()
    let host: String
    let kind: SitePermissionKind
    let decisionHandler: @MainActor @Sendable (WKPermissionDecision) -> Void
}

struct BrowserBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let url: URL
    let createdAt: Date
}

struct BrowserHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let url: URL
    var visitedAt: Date
}

struct BrowserLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BrowserStore
    let section: BrowserLibrarySection
    @State private var showingClearHistoryConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.text)
                    Text(section.subtitle)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.quiet)
                }

                Spacer()

                if section == .history {
                    Button("Clear History", role: .destructive) {
                        showingClearHistoryConfirmation = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Nodaysidle.ColorToken.danger)
                    .accessibilityLabel("Clear browsing history")
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Nodaysidle.ColorToken.muted)
                .accessibilityLabel("Close \(section.title)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)

            if section == .bookmarks {
                bookmarksContent
            } else {
                historyContent
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Nodaysidle.ColorToken.void)
        .confirmationDialog(
            "Clear History?",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                store.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the locally saved list of visited pages from this Mac.")
        }
    }

    @ViewBuilder
    private var bookmarksContent: some View {
        if store.bookmarks.isEmpty {
            LibraryEmptyState(
                symbol: "bookmark",
                title: "No bookmarks yet",
                message: "Use the Settings menu while viewing a page to save it here."
            )
        } else {
            List {
                ForEach(store.bookmarks) { bookmark in
                    BookmarkRow(
                        bookmark: bookmark,
                        open: {
                            store.navigateSelected(to: bookmark.url)
                            dismiss()
                        },
                        remove: {
                            store.removeBookmark(bookmark.id)
                        }
                    )
                    .listRowBackground(Nodaysidle.ColorToken.surface)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Nodaysidle.ColorToken.void)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if store.history.isEmpty {
            LibraryEmptyState(
                symbol: "clock",
                title: "No history yet",
                message: "Pages you finish loading will appear here."
            )
        } else {
            List {
                ForEach(store.history) { entry in
                    HistoryRow(
                        entry: entry,
                        open: {
                            store.navigateSelected(to: entry.url)
                            dismiss()
                        }
                    )
                    .listRowBackground(Nodaysidle.ColorToken.surface)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Nodaysidle.ColorToken.void)
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: BrowserBookmark
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    NodaysidleIcon(name: "bookmark", size: 13)
                        .foregroundStyle(Nodaysidle.ColorToken.accent)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookmark.title)
                            .lineLimit(1)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Nodaysidle.ColorToken.text)
                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                            .lineLimit(1)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Nodaysidle.ColorToken.muted)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open bookmark \(bookmark.title)")

            Button(action: remove) {
                NodaysidleIcon(name: "trash", size: 11)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Nodaysidle.ColorToken.quiet)
            .help("Remove bookmark")
            .accessibilityLabel("Remove bookmark \(bookmark.title)")
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryRow: View {
    let entry: BrowserHistoryEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                NodaysidleIcon(name: "clock", size: 13)
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.text)
                    Text(entry.url.host ?? entry.url.absoluteString)
                        .lineLimit(1)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.muted)
                }

                Spacer(minLength: 0)

                Text(entry.visitedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open history item \(entry.title)")
        .padding(.vertical, 4)
    }
}

private struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            NodaysidleIcon(name: symbol, size: 22)
                .foregroundStyle(Nodaysidle.ColorToken.quiet)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)
            Text(message)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
