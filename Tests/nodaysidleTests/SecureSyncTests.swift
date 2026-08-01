import Foundation
import XCTest
@testable import nodaysidle

final class SecureSyncTests: XCTestCase {
    func testEncryptedVaultRoundTripsWithoutPlaintext() throws {
        let bookmarkURL = try XCTUnwrap(URL(string: "https://example.com/private?tab=1"))
        let document = SecureSyncDocument(
            version: SecureSyncDocument.currentVersion,
            deviceID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            bookmarks: [
                BrowserBookmark(
                    id: UUID(),
                    title: "Private Example",
                    url: bookmarkURL,
                    createdAt: Date(timeIntervalSince1970: 900)
                ),
            ],
            history: [],
            deletedBookmarkURLs: [],
            deletedHistoryURLs: []
        )
        let material = try SecureSyncCrypto.makeKeyMaterial(passphrase: "correct horse battery staple")
        let encrypted = try SecureSyncCrypto.seal(document: document, using: material)

        XCTAssertFalse(String(data: encrypted, encoding: .utf8)?.contains("Private Example") == true)
        XCTAssertFalse(String(data: encrypted, encoding: .utf8)?.contains("example.com") == true)

        let opened = try SecureSyncCrypto.open(data: encrypted, passphrase: "correct horse battery staple")
        XCTAssertEqual(opened.document, document)
        XCTAssertEqual(opened.material, material)

        XCTAssertThrowsError(try SecureSyncCrypto.open(data: encrypted, passphrase: "wrong passphrase")) { error in
            XCTAssertEqual(error as? SecureSyncError, .incorrectPassphrase)
        }
    }

    func testMergeCombinesRecordsAndPropagatesDeletionTombstones() throws {
        let sharedURL = try XCTUnwrap(URL(string: "https://example.com/shared"))
        let remoteOnlyURL = try XCTUnwrap(URL(string: "https://example.com/remote"))
        let localOnlyURL = try XCTUnwrap(URL(string: "https://example.com/local"))
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let deletion = Date(timeIntervalSince1970: 300)

        let local = SecureSyncSnapshot(
            bookmarks: [
                BrowserBookmark(id: UUID(), title: "Local title", url: sharedURL, createdAt: newer),
            ],
            history: [
                BrowserHistoryEntry(id: UUID(), title: "Local history", url: localOnlyURL, visitedAt: newer),
            ],
            deletedBookmarkURLs: [SecureSyncTombstone(url: remoteOnlyURL, deletedAt: deletion)],
            deletedHistoryURLs: []
        )
        let remote = SecureSyncDocument(
            version: SecureSyncDocument.currentVersion,
            deviceID: UUID(),
            updatedAt: newer,
            bookmarks: [
                BrowserBookmark(id: UUID(), title: "Remote title", url: sharedURL, createdAt: older),
                BrowserBookmark(id: UUID(), title: "Remote only", url: remoteOnlyURL, createdAt: older),
            ],
            history: [],
            deletedBookmarkURLs: [],
            deletedHistoryURLs: []
        )

        let merged = SecureSyncFileStore.merge(
            snapshot: local,
            remote: remote,
            deviceID: UUID(),
            now: newer
        )

        XCTAssertEqual(merged.bookmarks.map(\.url), [sharedURL])
        XCTAssertEqual(merged.bookmarks.first?.title, "Local title")
        XCTAssertEqual(merged.deletedBookmarkURLs.map(\.url), [remoteOnlyURL])
        XCTAssertEqual(merged.history.map(\.url), [localOnlyURL])
    }

    func testSecondDeviceUnlocksAndMergesTheSameFolder() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodaysidle-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let firstURL = try XCTUnwrap(URL(string: "https://first.example"))
        let secondURL = try XCTUnwrap(URL(string: "https://second.example"))
        let firstSnapshot = SecureSyncSnapshot(
            bookmarks: [BrowserBookmark(id: UUID(), title: "First", url: firstURL, createdAt: Date(timeIntervalSince1970: 100))],
            history: [],
            deletedBookmarkURLs: [],
            deletedHistoryURLs: []
        )
        let secondSnapshot = SecureSyncSnapshot(
            bookmarks: [BrowserBookmark(id: UUID(), title: "Second", url: secondURL, createdAt: Date(timeIntervalSince1970: 200))],
            history: [],
            deletedBookmarkURLs: [],
            deletedHistoryURLs: []
        )

        let first = try SecureSyncFileStore.configureAndSynchronize(
            folderURL: folderURL,
            passphrase: "shared passphrase",
            snapshot: firstSnapshot,
            deviceID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        let second = try SecureSyncFileStore.configureAndSynchronize(
            folderURL: folderURL,
            passphrase: "shared passphrase",
            snapshot: secondSnapshot,
            deviceID: UUID(),
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(first.material, second.material)
        XCTAssertEqual(Set(second.document.bookmarks.map(\.url)), Set([firstURL, secondURL]))

        let encrypted = try Data(contentsOf: SecureSyncFileStore.syncFileURL(in: folderURL))
        let opened = try SecureSyncCrypto.open(data: encrypted, passphrase: "shared passphrase")
        XCTAssertEqual(Set(opened.document.bookmarks.map(\.url)), Set([firstURL, secondURL]))
    }
}
