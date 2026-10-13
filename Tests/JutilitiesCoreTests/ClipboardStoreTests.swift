import Foundation
import XCTest
@testable import JutilitiesCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

final class ClipboardStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JutilitiesClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func textCapture(_ text: String, source: String = "Tests") -> ClipboardCapture {
        ClipboardCapture(
            kind: text.hasPrefix("https://") ? .link : .text,
            title: String(text.prefix(100)), text: text,
            sourceApp: source, sourceBundleID: "dev.jutilities.tests",
            representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))]
        )
    }

    func testImageRepresentationsAndMetadataSurviveRestart() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let representations: [ClipboardRepresentation] = [
            .init(type: "public.png", data: png),
            .init(type: "com.example.original-image", data: Data([0, 255, 0, 17, 42])),
            .init(type: "com.example.empty-format", data: Data())
        ]
        var store: ClipboardStore? = try ClipboardStore(databaseURL: url)
        let capture = ClipboardCapture(
            kind: .image, title: "Screenshot", text: nil,
            sourceApp: "Screenshot Studio", sourceBundleID: "test.screenshots",
            representations: representations, thumbnail: png, imageWidth: 1, imageHeight: 1
        )
        let entry = try XCTUnwrap(store).insert(capture)
        try XCTUnwrap(store).setPinned(id: entry.id, pinned: true)
        store = nil

        let reopened = try ClipboardStore(databaseURL: url)
        let saved = try XCTUnwrap(reopened.entries().first)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(saved.kind, .image)
        XCTAssertEqual(saved.imageWidth, 1)
        XCTAssertEqual(saved.imageHeight, 1)
        XCTAssertEqual(saved.thumbnail, png)
        XCTAssertEqual(saved.sourceApp, "Screenshot Studio")
        XCTAssertTrue(saved.isPinned)
        XCTAssertEqual(saved.byteCount, png.count * 2 + 5)
        XCTAssertEqual(try reopened.representations(for: entry.id), representations)
        XCTAssertEqual(try reopened.entries(kind: .text), [])
    }

    func testUnicodeLiteralSearchAndInjectionSafety() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let match = try store.insert(textCapture("Grüße für O'Brien — 100% safe_name 👋 日本語"))
        _ = try store.insert(textCapture("ordinary 1000 safeXname"))
        for query in ["grusse", "FÜR", "O'Brien", "100%", "safe_name", "👋", "日本語", "—"] {
            XCTAssertEqual(try store.entries(search: query).map(\.id), [match.id], "Query: \(query)")
        }
        XCTAssertEqual(try store.entries(search: "\" OR 1=1 --"), [])
        XCTAssertEqual(try store.entries(search: "nonexistent"), [])
        XCTAssertEqual(try store.entries(limit: 0), [])
    }

    func testDeduplicationPreservesPinsAndOriginalCreationTime() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let firstTime = Date().addingTimeInterval(-60)
        let original = try store.insert(textCapture("Same payload", source: "First app"), now: firstTime)
        try store.setPinned(id: original.id, pinned: true)
        let nextTime = Date()
        let repeated = try store.insert(textCapture("Same payload", source: "Second app"), now: nextTime)
        XCTAssertEqual(repeated.id, original.id)
        XCTAssertEqual(repeated.createdAt.timeIntervalSince1970, firstTime.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(repeated.lastCopiedAt.timeIntervalSince1970, nextTime.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(repeated.isPinned)
        XCTAssertEqual(repeated.sourceApp, "Second app")
        XCTAssertEqual(try store.entries().count, 1)
    }

    func testDeduplicationIgnoresRepresentationOrderingButRestoresLatestOrdering() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let plain = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Hello".utf8))
        let rich = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1 Hello}".utf8))
        func capture(_ representations: [ClipboardRepresentation]) -> ClipboardCapture {
            ClipboardCapture(kind: .text, title: "Hello", text: "Hello", sourceApp: "Tests", sourceBundleID: nil, representations: representations)
        }
        let first = try store.insert(capture([plain, rich]))
        let second = try store.insert(capture([rich, plain]))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.representations(for: second.id), [rich, plain])
    }

    func testCleanupAtSixtyDaysIncludesPinnedItemsAndUsesLastCopyDate() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let reference = Date()
        let almostExpired = reference.addingTimeInterval(-ClipboardStore.retentionInterval + 10)
        let pinned = try store.insert(textCapture("Old pinned"), now: almostExpired)
        let recopied = try store.insert(textCapture("Old but recopied"), now: almostExpired)
        try store.setPinned(id: pinned.id, pinned: true)
        _ = try store.insert(textCapture("Old but recopied"), now: reference)
        XCTAssertEqual(try store.purgeExpired(now: reference.addingTimeInterval(10)), 1)
        XCTAssertEqual(try store.entries().map(\.id), [recopied.id])
        XCTAssertThrowsError(try store.representations(for: pinned.id))
    }

    func testReusingHistoryResetsRetentionAndSortsAsLatestCopy() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let reference = Date()
        let created = reference.addingTimeInterval(-59 * 24 * 60 * 60)
        let reused = try store.insert(textCapture("Reusable history item"), now: created)
        let recent = try store.insert(textCapture("More recent item"), now: reference.addingTimeInterval(-60))
        XCTAssertEqual(try store.entries().map(\.id), [recent.id, reused.id])

        try store.recordCopy(id: reused.id, now: reference)
        let rows = try store.entries()
        XCTAssertEqual(rows.map(\.id), [reused.id, recent.id])
        let touched = try XCTUnwrap(rows.first)
        XCTAssertEqual(touched.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(touched.lastCopiedAt.timeIntervalSince1970, reference.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try store.representations(for: reused.id), textCapture("Reusable history item").representations)
        try store.setPinned(id: reused.id, pinned: true)
        try store.recordCopy(id: reused.id, now: reference)
        XCTAssertTrue(try XCTUnwrap(store.entries().first).isPinned)
        XCTAssertEqual(try store.purgeExpired(now: reference.addingTimeInterval(ClipboardStore.retentionInterval - 1)), 1)
        XCTAssertEqual(try store.entries().map(\.id), [reused.id])
        XCTAssertEqual(try store.purgeExpired(now: reference.addingTimeInterval(ClipboardStore.retentionInterval)), 1)
        XCTAssertEqual(try store.entries(), [])
        XCTAssertThrowsError(try store.recordCopy(id: reused.id)) { error in
            guard case ClipboardStoreError.missingEntry = error else {
                return XCTFail("Expected missing entry, got \(error)")
            }
        }
    }

    func testDeleteAndClearRemovePayloadsAndSearchRows() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let first = try store.insert(textCapture("Delete this"))
        _ = try store.insert(textCapture("Keep this"))
        try store.delete(id: first.id)
        XCTAssertThrowsError(try store.representations(for: first.id))
        XCTAssertEqual(try store.entries(search: "Delete"), [])
        XCTAssertEqual(try store.entries().count, 1)
        try store.clear()
        XCTAssertEqual(try store.entries(), [])
        XCTAssertEqual(try store.entries(search: "Keep"), [])
        // Image payloads and all other formats are inside SQLite; no sidecar images.
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(files.allSatisfy { $0.hasPrefix("history.sqlite") })
    }

    func testBackupRestoresLiveWALPayloadsAndReplacesPreviousSnapshot() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let backup = folder.appendingPathComponent("backup.sqlite")
        let original = try store.insert(textCapture("Backup contents"))
        try store.setPinned(id: original.id, pinned: true)
        try store.backup(to: backup)
        var restored: ClipboardStore? = try ClipboardStore(databaseURL: backup)
        XCTAssertEqual(try XCTUnwrap(restored).entries().map(\.id), [original.id])
        XCTAssertEqual(try XCTUnwrap(restored).representations(for: original.id), textCapture("Backup contents").representations)
        XCTAssertEqual(try XCTUnwrap(restored).entries().first?.isPinned, true)
        restored = nil

        try store.delete(id: original.id)
        let replacement = try store.insert(textCapture("Latest contents"))
        try store.backup(to: backup)
        let latest = try ClipboardStore(databaseURL: backup)
        XCTAssertEqual(try latest.entries().map(\.id), [replacement.id])
        XCTAssertEqual(try latest.entries(search: "Backup contents"), [])
        XCTAssertThrowsError(try store.backup(to: store.databaseURL))
        XCTAssertThrowsError(try store.backup(to: URL(fileURLWithPath: store.databaseURL.path + "-wal")))
    }

    func testStorageAndBackupPermissionsArePrivate() throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Clipboard")
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        _ = try store.insert(textCapture("Private contents"))
        let backup = folder.appendingPathComponent("backup.sqlite")
        try store.backup(to: backup)
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderPermissions?.intValue, 0o700)
        for path in [store.databaseURL.path, backup.path] {
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testExportPreservesExistingDestinationDirectoryPermissions() throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let storage = parent.appendingPathComponent("Clipboard")
        let store = try ClipboardStore(databaseURL: storage.appendingPathComponent("history.sqlite"))
        _ = try store.insert(textCapture("Exported history"))
        let destination = parent.appendingPathComponent("Shared export folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        let backup = destination.appendingPathComponent("clipboard.sqlite")
        try store.backup(to: backup)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
    }

    func testRestoreRecoversPayloadsAndPinsThenPurgesExpiredEntries() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try ClipboardStore(databaseURL: folder.appendingPathComponent("original.sqlite"))
        let now = Date()
        let expiresSoon = try original.insert(
            textCapture("Expires during restore"),
            now: now.addingTimeInterval(-ClipboardStore.retentionInterval + 10)
        )
        try original.setPinned(id: expiresSoon.id, pinned: true)
        let current = try original.insert(textCapture("Restored current content"), now: now)
        try original.setPinned(id: current.id, pinned: true)
        let backup = folder.appendingPathComponent("backup.sqlite")
        try original.backup(to: backup)

        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        _ = try live.insert(textCapture("Replaced live history"))
        try live.restore(from: backup, now: now.addingTimeInterval(10))
        let rows = try live.entries()
        XCTAssertEqual(rows.map(\.id), [current.id])
        XCTAssertTrue(try XCTUnwrap(rows.first).isPinned)
        XCTAssertEqual(try live.representations(for: current.id), textCapture("Restored current content").representations)
        XCTAssertThrowsError(try live.representations(for: expiresSoon.id))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".clipboard-restore-") })
    }

    func testCorruptOrForeignRestoreLeavesExistingHistoryUntouched() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        let existing = try live.insert(textCapture("Keep this live content"))
        let corrupt = folder.appendingPathComponent("corrupt.sqlite")
        try Data("Not a backup".utf8).write(to: corrupt)
        XCTAssertThrowsError(try live.restore(from: corrupt))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        XCTAssertEqual(try live.representations(for: existing.id), textCapture("Keep this live content").representations)

        let foreign = folder.appendingPathComponent("foreign.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(foreign.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE unrelated (value TEXT); PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        XCTAssertThrowsError(try live.restore(from: foreign))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        XCTAssertThrowsError(try live.restore(from: live.databaseURL))
    }

    func testRepeatedRestoreCleansStagingFilesAfterSQLiteRemovesItsSidecars() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try ClipboardStore(databaseURL: folder.appendingPathComponent("original.sqlite"))
        let saved = try original.insert(textCapture("Saved restore content"))
        let backup = folder.appendingPathComponent("backup.sqlite")
        try original.backup(to: backup)
        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        for index in 0..<5 {
            _ = try live.insert(textCapture("Temporary live entry \(index)"))
            try live.restore(from: backup)
            XCTAssertEqual(try live.entries().map(\.id), [saved.id])
            XCTAssertEqual(try live.representations(for: saved.id), textCapture("Saved restore content").representations)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertFalse(files.contains { $0.hasPrefix(".clipboard-restore-") })
        }
    }

    func testRestoreReadsLegacyWALHeaderBackupWithoutWritingSourceSidecars() throws {
        let folder = try directory()
        let backupFolder = folder.appendingPathComponent("Read only backups")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backupFolder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let original = try ClipboardStore(databaseURL: folder.appendingPathComponent("original.sqlite"))
        let saved = try original.insert(textCapture("Legacy snapshot content"))
        let backup = backupFolder.appendingPathComponent("legacy.sqlite")
        try original.backup(to: backup)
        // Early snapshots were complete SQLite files with a WAL-mode header,
        // but no -wal/-shm files after their writer closed.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(backup.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))
        let sourceBytes = try Data(contentsOf: backup)
        XCTAssertEqual(Array(sourceBytes[18...19]), [2, 2])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: backup.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backupFolder.path)

        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        try live.restore(from: backup)
        XCTAssertEqual(try live.entries().map(\.id), [saved.id])
        XCTAssertEqual(try Data(contentsOf: backup), sourceBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-shm"))
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444)
    }

    func testRestoreRejectsSymlinkToActiveWALWithoutChangingEitherHistory() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try ClipboardStore(databaseURL: folder.appendingPathComponent("source.sqlite"))
        let baseline = try source.insert(textCapture("Checkpointed source"))
        var checkpoint: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.databaseURL.path, &checkpoint), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(checkpoint, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(checkpoint), SQLITE_OK)
        let pending = try source.insert(textCapture("Committed content in source WAL"))
        let wal = URL(fileURLWithPath: source.databaseURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        let sourceBytes = try Data(contentsOf: source.databaseURL)
        let walBytes = try Data(contentsOf: wal)
        let alias = folder.appendingPathComponent("source-alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.databaseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path + "-wal"))
        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        let existing = try live.insert(textCapture("Live history to preserve"))

        XCTAssertThrowsError(try live.restore(from: alias))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        XCTAssertEqual(try Data(contentsOf: source.databaseURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: wal), walBytes)
        XCTAssertEqual(try source.entries().map(\.id), [pending.id, baseline.id])
        XCTAssertEqual(try source.representations(for: pending.id), textCapture("Committed content in source WAL").representations)
    }

    func testRestoreRejectsPendingRollbackJournalAndPreservesSource() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try ClipboardStore(databaseURL: folder.appendingPathComponent("original.sqlite"))
        _ = try original.insert(textCapture("Backup content"))
        let backup = folder.appendingPathComponent("backup.sqlite")
        try original.backup(to: backup)
        let sourceBytes = try Data(contentsOf: backup)
        let journal = URL(fileURLWithPath: backup.path + "-journal")
        // A hot rollback journal starts with SQLite's journal magic. Recovery
        // must be left to SQLite rather than ignored by immutable import.
        let journalBytes = Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]) + Data(repeating: 0, count: 1_016)
        try journalBytes.write(to: journal)
        let alias = folder.appendingPathComponent("backup-alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)
        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        let existing = try live.insert(textCapture("Live content"))

        XCTAssertThrowsError(try live.restore(from: backup))
        XCTAssertThrowsError(try live.restore(from: alias))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        XCTAssertEqual(try Data(contentsOf: backup), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    }

    func testInvalidCapturesAndDamagedDatabasesProduceErrors() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let empty = ClipboardCapture(kind: .text, title: "No formats", text: "Hello", sourceApp: "Tests", sourceBundleID: nil, representations: [])
        XCTAssertThrowsError(try store.insert(empty))
        let invalid = ClipboardCapture(kind: .image, title: "Invalid dimensions", text: nil, sourceApp: "Tests", sourceBundleID: nil, representations: [.init(type: "public.png", data: Data([1, 2]))], imageWidth: -1, imageHeight: 1)
        XCTAssertThrowsError(try store.insert(invalid))
        XCTAssertThrowsError(try store.setPinned(id: "missing", pinned: true))
        XCTAssertEqual(try store.entries(), [])
        let corrupt = folder.appendingPathComponent("corrupt.sqlite")
        try Data("This is not SQLite".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ClipboardStore(databaseURL: corrupt))
        XCTAssertThrowsError(try ClipboardStore(databaseURL: XCTUnwrap(URL(string: "https://example.com/history.sqlite"))))
    }

    func testFutureSchemaIsNotOverwritten() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("future.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        XCTAssertThrowsError(try ClipboardStore(databaseURL: url)) { error in
            guard case ClipboardStoreError.unsupportedSchema(999) = error else {
                return XCTFail("Expected an unsupported-schema error, got \(error)")
            }
        }
    }

    func testConcurrentInsertsAreSerialized() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                let text = "Concurrent item \(index)"
                let capture = textCapture(text)
                group.addTask { _ = try store.insert(capture) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try store.entries().count, 30)
    }
}
