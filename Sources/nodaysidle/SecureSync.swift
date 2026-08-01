import CryptoKit
import Foundation
import Security

enum SecureSyncStatus: Equatable, Sendable {
    case disabled
    case locked
    case ready
    case syncing
    case failed(String)

    var label: String {
        switch self {
        case .disabled:
            return "Off"
        case .locked:
            return "Locked"
        case .ready:
            return "Ready"
        case .syncing:
            return "Syncing…"
        case .failed:
            return "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled:
            return "arrow.triangle.2.circlepath"
        case .locked:
            return "lock"
        case .ready:
            return "checkmark.circle"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}

enum SecureSyncOperationResult: Equatable, Sendable {
    case synced
    case notConfigured
    case locked
    case failed(String)
}

struct SecureSyncTombstone: Codable, Equatable, Sendable {
    let url: URL
    let deletedAt: Date
}

struct SecureSyncSnapshot: Codable, Equatable, Sendable {
    let bookmarks: [BrowserBookmark]
    let history: [BrowserHistoryEntry]
    let deletedBookmarkURLs: [SecureSyncTombstone]
    let deletedHistoryURLs: [SecureSyncTombstone]
}

struct SecureSyncKeyMaterial: Codable, Equatable, Sendable {
    let salt: Data
    let key: Data
}

struct SecureSyncConfiguredVault: Sendable {
    let document: SecureSyncDocument
    let material: SecureSyncKeyMaterial
}

struct SecureSyncDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let deviceID: UUID
    let updatedAt: Date
    let bookmarks: [BrowserBookmark]
    let history: [BrowserHistoryEntry]
    let deletedBookmarkURLs: [SecureSyncTombstone]
    let deletedHistoryURLs: [SecureSyncTombstone]
}

private struct SecureSyncEnvelope: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let salt: Data
    let sealedData: Data
}

enum SecureSyncError: LocalizedError, Equatable, Sendable {
    case emptyPassphrase
    case folderUnavailable
    case invalidSyncFile
    case unsupportedVersion(Int)
    case incorrectPassphrase
    case randomGenerationFailed
    case invalidKeychainItem
    case keychain(Int32)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return "Enter a passphrase to protect the sync vault."
        case .folderUnavailable:
            return "The selected sync folder is not available."
        case .invalidSyncFile:
            return "The sync vault is invalid or incomplete."
        case let .unsupportedVersion(version):
            return "This sync vault uses an unsupported version (\(version))."
        case .incorrectPassphrase:
            return "That passphrase could not unlock the sync vault."
        case .randomGenerationFailed:
            return "The system could not generate secure sync material."
        case .invalidKeychainItem:
            return "The saved sync key is invalid. Set up secure sync again."
        case let .keychain(status):
            return "macOS Keychain rejected the sync key (status \(status))."
        case let .io(message):
            return message
        }
    }
}

enum SecureSyncCrypto {
    static let saltByteCount = 16
    static let derivedKeyByteCount = 32
    static let pbkdf2Iterations = 210_000

    static func makeKeyMaterial(passphrase: String, salt: Data? = nil) throws -> SecureSyncKeyMaterial {
        guard !passphrase.isEmpty else { throw SecureSyncError.emptyPassphrase }
        let resolvedSalt = try salt ?? makeSalt()
        guard resolvedSalt.count == saltByteCount else {
            throw SecureSyncError.invalidSyncFile
        }
        return SecureSyncKeyMaterial(
            salt: resolvedSalt,
            key: deriveKey(passphrase: passphrase, salt: resolvedSalt)
        )
    }

    static func seal(document: SecureSyncDocument, using material: SecureSyncKeyMaterial) throws -> Data {
        guard material.salt.count == saltByteCount,
              material.key.count == derivedKeyByteCount
        else { throw SecureSyncError.invalidSyncFile }

        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(document)
        } catch {
            throw SecureSyncError.io("Could not encode the sync vault.")
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: material.key))
        } catch {
            throw SecureSyncError.io("Could not encrypt the sync vault.")
        }

        guard let combined = sealedBox.combined else {
            throw SecureSyncError.io("Could not finalize the encrypted sync vault.")
        }

        let envelope = SecureSyncEnvelope(
            version: SecureSyncEnvelope.currentVersion,
            salt: material.salt,
            sealedData: combined
        )
        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            throw SecureSyncError.io("Could not write the encrypted sync vault.")
        }
    }

    static func open(data: Data, passphrase: String) throws -> (document: SecureSyncDocument, material: SecureSyncKeyMaterial) {
        let envelope = try decodeEnvelope(data)
        let material = try makeKeyMaterial(passphrase: passphrase, salt: envelope.salt)
        return (try open(data: data, using: material), material)
    }

    static func open(data: Data, using material: SecureSyncKeyMaterial) throws -> SecureSyncDocument {
        let envelope = try decodeEnvelope(data)
        guard envelope.salt == material.salt else {
            throw SecureSyncError.incorrectPassphrase
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedData)
        } catch {
            throw SecureSyncError.invalidSyncFile
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: material.key))
        } catch {
            throw SecureSyncError.incorrectPassphrase
        }

        do {
            let document = try JSONDecoder().decode(SecureSyncDocument.self, from: plaintext)
            guard document.version <= SecureSyncDocument.currentVersion else {
                throw SecureSyncError.unsupportedVersion(document.version)
            }
            return document
        } catch let error as SecureSyncError {
            throw error
        } catch {
            throw SecureSyncError.invalidSyncFile
        }
    }

    private static func decodeEnvelope(_ data: Data) throws -> SecureSyncEnvelope {
        let envelope: SecureSyncEnvelope
        do {
            envelope = try JSONDecoder().decode(SecureSyncEnvelope.self, from: data)
        } catch {
            throw SecureSyncError.invalidSyncFile
        }
        guard envelope.version <= SecureSyncEnvelope.currentVersion,
              envelope.salt.count == saltByteCount,
              !envelope.sealedData.isEmpty
        else {
            if envelope.version > SecureSyncEnvelope.currentVersion {
                throw SecureSyncError.unsupportedVersion(envelope.version)
            }
            throw SecureSyncError.invalidSyncFile
        }
        return envelope
    }

    private static func makeSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        let result: Int32 = bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard result == errSecSuccess else {
            throw SecureSyncError.randomGenerationFailed
        }
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data) -> Data {
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var derived = Data()
        var blockIndex: UInt32 = 1

        while derived.count < derivedKeyByteCount {
            var message = salt
            message.append(UInt8((blockIndex >> 24) & 0xff))
            message.append(UInt8((blockIndex >> 16) & 0xff))
            message.append(UInt8((blockIndex >> 8) & 0xff))
            message.append(UInt8(blockIndex & 0xff))

            var u = hmac(message, using: passwordKey)
            var t = u
            for _ in 1..<pbkdf2Iterations {
                u = hmac(u, using: passwordKey)
                for index in t.indices {
                    t[index] ^= u[index]
                }
            }
            derived.append(t)
            blockIndex += 1
        }

        return Data(derived.prefix(derivedKeyByteCount))
    }

    private static func hmac(_ message: Data, using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

enum SecureSyncKeychain {
    private static let service = "com.nodaysidle.browser.secure-sync"
    private static let account = "library-key"

    static func load() throws -> SecureSyncKeyMaterial? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecureSyncError.keychain(status)
        }
        guard let data = result as? Data else {
            throw SecureSyncError.invalidKeychainItem
        }
        do {
            return try JSONDecoder().decode(SecureSyncKeyMaterial.self, from: data)
        } catch {
            throw SecureSyncError.invalidKeychainItem
        }
    }

    static func save(_ material: SecureSyncKeyMaterial) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(material)
        } catch {
            throw SecureSyncError.invalidKeychainItem
        }

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecureSyncError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureSyncError.keychain(addStatus)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSyncError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum SecureSyncFileStore {
    static let fileName = ".nodaysidle-library.sync"
    static let maxHistoryEntries = 500
    static let maxTombstones = 1_000

    static func configureAndSynchronize(
        folderURL: URL,
        passphrase: String,
        snapshot: SecureSyncSnapshot,
        deviceID: UUID,
        now: Date = Date()
    ) throws -> (document: SecureSyncDocument, material: SecureSyncKeyMaterial) {
        try validateFolder(folderURL)
        let fileURL = syncFileURL(in: folderURL)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try read(fileURL)
            let opened = try SecureSyncCrypto.open(data: data, passphrase: passphrase)
            let document = try synchronize(
                folderURL: folderURL,
                snapshot: snapshot,
                material: opened.material,
                deviceID: deviceID,
                now: now
            )
            return (document, opened.material)
        }

        let material = try SecureSyncCrypto.makeKeyMaterial(passphrase: passphrase)
        let document = try synchronize(
            folderURL: folderURL,
            snapshot: snapshot,
            material: material,
            deviceID: deviceID,
            now: now
        )
        return (document, material)
    }

    static func synchronize(
        folderURL: URL,
        snapshot: SecureSyncSnapshot,
        material: SecureSyncKeyMaterial,
        deviceID: UUID,
        now: Date = Date()
    ) throws -> SecureSyncDocument {
        try validateFolder(folderURL)
        let fileURL = syncFileURL(in: folderURL)
        var remote: SecureSyncDocument?

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try read(fileURL)
            remote = try SecureSyncCrypto.open(data: data, using: material)
        }

        let document = merge(snapshot: snapshot, remote: remote, deviceID: deviceID, now: now)
        let encrypted = try SecureSyncCrypto.seal(document: document, using: material)
        do {
            try encrypted.write(to: fileURL, options: [.atomic])
        } catch {
            throw SecureSyncError.io("Could not write the sync vault to the selected folder.")
        }
        return document
    }

    static func syncFileURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func merge(
        snapshot: SecureSyncSnapshot,
        remote: SecureSyncDocument?,
        deviceID: UUID,
        now: Date
    ) -> SecureSyncDocument {
        var bookmarkStates: [String: BookmarkState] = [:]

        func acceptBookmark(_ bookmark: BrowserBookmark) {
            let key = bookmark.url.absoluteString
            let candidate = BookmarkState(
                bookmark: bookmark,
                deletedAt: nil,
                timestamp: bookmark.createdAt,
                urlString: key
            )
            if shouldReplace(bookmarkStates[key]?.timestamp, with: candidate.timestamp, deletion: false) {
                bookmarkStates[key] = candidate
            }
        }

        func acceptBookmarkDeletion(_ tombstone: SecureSyncTombstone) {
            let key = tombstone.url.absoluteString
            let candidate = BookmarkState(
                bookmark: nil,
                deletedAt: tombstone.deletedAt,
                timestamp: tombstone.deletedAt,
                urlString: key
            )
            if shouldReplace(bookmarkStates[key]?.timestamp, with: candidate.timestamp, deletion: true) {
                bookmarkStates[key] = candidate
            }
        }

        snapshot.bookmarks.forEach(acceptBookmark)
        snapshot.deletedBookmarkURLs.forEach(acceptBookmarkDeletion)
        remote?.bookmarks.forEach(acceptBookmark)
        remote?.deletedBookmarkURLs.forEach(acceptBookmarkDeletion)

        var bookmarks: [BrowserBookmark] = []
        var deletedBookmarks: [SecureSyncTombstone] = []
        for state in bookmarkStates.values {
            if let bookmark = state.bookmark {
                bookmarks.append(bookmark)
            } else if let deletedAt = state.deletedAt,
                      let url = URL(string: state.urlString)
            {
                deletedBookmarks.append(SecureSyncTombstone(url: url, deletedAt: deletedAt))
            }
        }
        bookmarks.sort { $0.createdAt > $1.createdAt }
        deletedBookmarks.sort { $0.deletedAt > $1.deletedAt }
        deletedBookmarks = Array(deletedBookmarks.prefix(maxTombstones))

        var historyStates: [String: HistoryState] = [:]

        func acceptHistory(_ entry: BrowserHistoryEntry) {
            let key = entry.url.absoluteString
            let candidate = HistoryState(
                entry: entry,
                deletedAt: nil,
                timestamp: entry.visitedAt,
                urlString: key
            )
            if shouldReplace(historyStates[key]?.timestamp, with: candidate.timestamp, deletion: false) {
                historyStates[key] = candidate
            }
        }

        func acceptHistoryDeletion(_ tombstone: SecureSyncTombstone) {
            let key = tombstone.url.absoluteString
            let candidate = HistoryState(
                entry: nil,
                deletedAt: tombstone.deletedAt,
                timestamp: tombstone.deletedAt,
                urlString: key
            )
            if shouldReplace(historyStates[key]?.timestamp, with: candidate.timestamp, deletion: true) {
                historyStates[key] = candidate
            }
        }

        snapshot.history.forEach(acceptHistory)
        snapshot.deletedHistoryURLs.forEach(acceptHistoryDeletion)
        remote?.history.forEach(acceptHistory)
        remote?.deletedHistoryURLs.forEach(acceptHistoryDeletion)

        var history: [BrowserHistoryEntry] = []
        var deletedHistory: [SecureSyncTombstone] = []
        for state in historyStates.values {
            if let entry = state.entry {
                history.append(entry)
            } else if let deletedAt = state.deletedAt,
                      let url = URL(string: state.urlString)
            {
                deletedHistory.append(SecureSyncTombstone(url: url, deletedAt: deletedAt))
            }
        }
        history.sort { $0.visitedAt > $1.visitedAt }
        history = Array(history.prefix(maxHistoryEntries))
        deletedHistory.sort { $0.deletedAt > $1.deletedAt }
        deletedHistory = Array(deletedHistory.prefix(maxTombstones))

        return SecureSyncDocument(
            version: SecureSyncDocument.currentVersion,
            deviceID: deviceID,
            updatedAt: now,
            bookmarks: bookmarks,
            history: history,
            deletedBookmarkURLs: deletedBookmarks,
            deletedHistoryURLs: deletedHistory
        )
    }

    private struct BookmarkState {
        let bookmark: BrowserBookmark?
        let deletedAt: Date?
        let timestamp: Date
        let urlString: String
    }

    private struct HistoryState {
        let entry: BrowserHistoryEntry?
        let deletedAt: Date?
        let timestamp: Date
        let urlString: String
    }

    private static func shouldReplace(_ existing: Date?, with candidate: Date, deletion: Bool) -> Bool {
        guard let existing else { return true }
        if candidate != existing { return candidate > existing }
        return deletion
    }

    private static func validateFolder(_ folderURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SecureSyncError.folderUnavailable
        }
    }

    private static func read(_ fileURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw SecureSyncError.io("Could not read the sync vault from the selected folder.")
        }
    }
}
