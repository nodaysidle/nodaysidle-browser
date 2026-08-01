import AppKit
import SwiftUI

struct SecureSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BrowserStore
    @State private var folderURL: URL?
    @State private var passphrase = ""
    @State private var confirmationPassphrase = ""
    @State private var isEditingSetup = false
    @State private var isWorking = false
    @State private var showingDisableConfirmation = false
    @State private var localError: String?

    init(store: BrowserStore) {
        self.store = store
        _folderURL = State(initialValue: store.secureSyncFolderURL)
        _isEditingSetup = State(initialValue: !store.secureSyncIsConfigured || !store.secureSyncIsUnlocked)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Nodaysidle.ColorToken.line)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    explanation
                    statusCard

                    if isEditingSetup {
                        setupForm
                    } else {
                        activeControls
                    }

                    if let localError {
                        Text(localError)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Nodaysidle.ColorToken.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Secure sync error: \(localError)")
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 580, minHeight: 500)
        .background(Nodaysidle.ColorToken.void)
        .confirmationDialog(
            "Disable Secure Sync?",
            isPresented: $showingDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disable Secure Sync", role: .destructive) {
                store.disableSecureSync()
                if store.secureSyncIsConfigured {
                    localError = store.secureSyncErrorMessage
                } else {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local Keychain key and stops synchronization. The encrypted vault stays in the shared folder.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Secure Sync")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.text)
                Text("Optional encrypted bookmarks and history")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Nodaysidle.ColorToken.muted)
            .accessibilityLabel("Close Secure Sync")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use a folder already synchronized by iCloud Drive, Dropbox, or another trusted file service. nodaysidle writes one encrypted vault there; it does not upload your browsing library to its own server.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your passphrase is never written to the vault. This Mac keeps the derived encryption key in Keychain, so you will not need to unlock sync every launch. Set it up separately on another Mac with the same folder and passphrase.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            NodaysidleIcon(name: store.secureSyncStatus.symbolName, size: 16)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Status: \(store.secureSyncStatus.label)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.text)
                if let path = store.secureSyncFolderPath {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.quiet)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("No shared folder selected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.quiet)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Nodaysidle.ColorToken.surface)
        .clipShape(.rect(cornerRadius: Nodaysidle.Metric.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Nodaysidle.Metric.controlRadius)
                .stroke(Nodaysidle.ColorToken.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Secure sync status: \(store.secureSyncStatus.label)")
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.secureSyncIsConfigured ? "Unlock or change sync" : "Set up secure sync")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderURL?.path ?? "Choose a shared folder")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(folderURL == nil ? Nodaysidle.ColorToken.quiet : Nodaysidle.ColorToken.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("The encrypted vault will be saved as \(SecureSyncFileStore.fileName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Nodaysidle.ColorToken.quiet)
                }

                Spacer(minLength: 0)

                Button("Choose…", action: chooseFolder)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .background(Nodaysidle.ColorToken.surface)
            .clipShape(.rect(cornerRadius: Nodaysidle.Metric.controlRadius))

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Secure sync passphrase")

            if !store.secureSyncIsConfigured || isChangingFolder {
                SecureField("Confirm passphrase", text: $confirmationPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Confirm secure sync passphrase")
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    cancelSetup()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(store.secureSyncIsConfigured ? "Unlock & Sync" : "Enable Secure Sync") {
                    configure()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync is enabled on this Mac.")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Nodaysidle.ColorToken.text)

            if let lastSync = store.secureSyncLastSyncDate {
                Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Nodaysidle.ColorToken.quiet)
            }

            HStack(spacing: 10) {
                Button("Sync Now") {
                    syncNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isWorking || store.secureSyncIsSyncing)

                Button("Change Folder…") {
                    isEditingSetup = true
                    folderURL = store.secureSyncFolderURL
                    passphrase = ""
                    confirmationPassphrase = ""
                    localError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Disable", role: .destructive) {
                    showingDisableConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var isChangingFolder: Bool {
        store.secureSyncIsConfigured && folderURL != store.secureSyncFolderURL
    }

    private var statusColor: Color {
        switch store.secureSyncStatus {
        case .failed:
            return Nodaysidle.ColorToken.danger
        case .locked:
            return Nodaysidle.ColorToken.muted
        case .disabled:
            return Nodaysidle.ColorToken.quiet
        case .ready, .syncing:
            return Nodaysidle.ColorToken.accent
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Shared Folder"
        if panel.runModal() == .OK {
            folderURL = panel.url
        }
    }

    private func configure() {
        guard let folderURL else {
            localError = "Choose a shared folder first."
            return
        }
        guard !passphrase.isEmpty else {
            localError = SecureSyncError.emptyPassphrase.localizedDescription
            return
        }
        if !store.secureSyncIsConfigured || isChangingFolder,
           passphrase != confirmationPassphrase
        {
            localError = "The passphrases do not match."
            return
        }

        isWorking = true
        localError = nil
        Task { @MainActor in
            let result = await store.configureSecureSync(folderURL: folderURL, passphrase: passphrase)
            isWorking = false
            passphrase = ""
            confirmationPassphrase = ""
            switch result {
            case .synced:
                isEditingSetup = false
            case .failed(let message):
                localError = message
            case .locked:
                localError = "Enter the passphrase to unlock the sync vault."
            case .notConfigured:
                localError = "Secure sync is not configured."
            }
        }
    }

    private func syncNow() {
        isWorking = true
        localError = nil
        Task { @MainActor in
            let result = await store.syncSecureLibrary()
            isWorking = false
            if case let .failed(message) = result {
                localError = message
            }
        }
    }

    private func cancelSetup() {
        if store.secureSyncIsConfigured && store.secureSyncIsUnlocked {
            isEditingSetup = false
            folderURL = store.secureSyncFolderURL
        } else {
            dismiss()
        }
        passphrase = ""
        confirmationPassphrase = ""
        localError = nil
    }
}
