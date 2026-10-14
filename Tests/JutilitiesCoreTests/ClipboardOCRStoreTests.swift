import Foundation
import XCTest
@testable import JutilitiesCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

final class ClipboardOCRStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JutilitiesOCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(_ number: UInt8 = 1, title: String = "Image", source: String = "Tests") -> ClipboardCapture {
        ClipboardCapture(
            kind: .image, title: title, text: "Original image description", sourceApp: source,
            sourceBundleID: "dev.jutilities.tests", representations: [
                .init(type: "public.png", data: Data([number, 2, 3])),
                .init(type: "public.tiff", data: Data([number, 4, 5]))
            ], thumbnail: Data([number]), imageWidth: 100, imageHeight: 50
        )
    }

    private func text() -> ClipboardCapture {
        ClipboardCapture(kind: .text, title: "Text", text: "Text", sourceApp: "Tests", sourceBundleID: nil,
                         representations: [.init(type: "public.utf8-plain-text", data: Data("Text".utf8))])
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ClipboardStoreError.database("Could not open test fixture.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipboardStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func rowCount(_ table: String, at url: URL) throws -> Int {
        // Only fixed test table names are passed to this helper.
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw ClipboardStoreError.database("Could not open test fixture.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.database("Could not query test fixture.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ClipboardStoreError.database("Could not read test fixture.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func makeLegacyBackup(from store: ClipboardStore, to url: URL) throws {
        try store.backup(to: url)
        // v1 used exactly this schema without the appended OCR column. Removing
        // it recreates that original table SQL while preserving payloads/FTS.
        try execute("ALTER TABLE entries DROP COLUMN recognized_text; PRAGMA user_version = 1", at: url)
    }

    func testRecognitionPersistsAndSearchesUnicodeWithoutChangingImageOrRetention() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        var store: ClipboardStore? = try ClipboardStore(databaseURL: url)
        let copied = Date().addingTimeInterval(-60)
        let capture = image()
        let original = try XCTUnwrap(store).insert(capture, now: copied)
        let recognized = "Grüße für O'Brien — 100% safe_name 👋 日本語 \"Quoted\""
        XCTAssertTrue(try XCTUnwrap(store).setRecognizedText(recognized, for: original.id))
        store = nil

        let reopened = try ClipboardStore(databaseURL: url)
        let entry = try XCTUnwrap(reopened.entries().first)
        XCTAssertEqual(entry.recognizedText, recognized)
        XCTAssertEqual(try reopened.recognizedText(for: entry.id), recognized)
        XCTAssertEqual(entry.previewText, capture.text)
        XCTAssertEqual(entry.lastCopiedAt.timeIntervalSince1970, copied.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entry.createdAt.timeIntervalSince1970, copied.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entry.thumbnail, capture.thumbnail)
        XCTAssertEqual(try reopened.representations(for: entry.id), capture.representations)
        for query in ["grusse", "FÜR", "O'Brien", "100%", "safe_name", "👋", "日本語", "\"Quoted\"", "Original image description"] {
            XCTAssertEqual(try reopened.entries(search: query).map(\.id), [entry.id], "Query: \(query)")
        }
        XCTAssertEqual(try reopened.entries(search: "\" OR 1=1 --"), [])
        XCTAssertEqual(try reopened.imagesNeedingRecognition(), [])
        XCTAssertTrue(try reopened.setRecognizedText("ReplacementOCRToken", for: entry.id))
        XCTAssertEqual(try reopened.entries(search: "ReplacementOCRToken").map(\.id), [entry.id])
        XCTAssertEqual(try reopened.entries(search: "grusse"), [])
    }

    func testRecaptureKeepsRecognitionAndSearchesNewMetadata() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let first = try store.insert(image(title: "OldTitle", source: "OldSource"), now: Date().addingTimeInterval(-120))
        try store.setPinned(id: first.id, pinned: true)
        XCTAssertTrue(try store.setRecognizedText("OCR survives deduplication", for: first.id))
        let repeated = try store.insert(image(title: "NewTitle", source: "NewSource"))
        XCTAssertEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.recognizedText, "OCR survives deduplication")
        XCTAssertTrue(repeated.isPinned)
        XCTAssertEqual(repeated.createdAt, first.createdAt)
        XCTAssertEqual(try store.entries(search: "survives").map(\.id), [first.id])
        XCTAssertEqual(try store.entries(search: "NewTitle").map(\.id), [first.id])
        XCTAssertEqual(try store.entries(search: "NewSource").map(\.id), [first.id])
        XCTAssertEqual(try store.entries(search: "OldTitle"), [])
        XCTAssertEqual(try store.entries(search: "OldSource"), [])
        XCTAssertEqual(try store.imagesNeedingRecognition(), [])
    }

    func testPendingWorkIsBoundedOrderedAndCanSkipFailuresAndCompletedEmptyText() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        var store: ClipboardStore? = try ClipboardStore(databaseURL: url)
        let first = try XCTUnwrap(store).insert(image(1), now: Date().addingTimeInterval(-120))
        let second = try XCTUnwrap(store).insert(image(2), now: Date().addingTimeInterval(-60))
        let newest = try XCTUnwrap(store).insert(image(3))
        _ = try XCTUnwrap(store).insert(text())
        XCTAssertEqual(try XCTUnwrap(store).imagesNeedingRecognition(limit: 0), [])
        XCTAssertEqual(try XCTUnwrap(store).imagesNeedingRecognition().map(\.id), [newest.id])
        XCTAssertEqual(try XCTUnwrap(store).imagesNeedingRecognition(limit: 2, excludingIDs: [newest.id]).map(\.id), [second.id, first.id])
        XCTAssertTrue(try XCTUnwrap(store).setRecognizedText("", for: second.id))
        store = nil
        let reopened = try ClipboardStore(databaseURL: url)
        XCTAssertEqual(try reopened.recognizedText(for: second.id), "")
        XCTAssertNil(try reopened.recognizedText(for: first.id))
        XCTAssertEqual(try reopened.imagesNeedingRecognition(limit: 10).map(\.id), [newest.id, first.id])
    }

    func testLateRecognitionNeverRecreatesDeletedExpiredOrClearedImages() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let store = try ClipboardStore(databaseURL: url)
        let deleted = try store.insert(image(1))
        XCTAssertTrue(try store.setRecognizedText("DeletedOCRToken", for: deleted.id))
        try store.delete(id: deleted.id)
        XCTAssertFalse(try store.setRecognizedText("Late text", for: deleted.id))
        XCTAssertNil(try store.recognizedText(for: deleted.id))
        XCTAssertEqual(try store.entries(search: "DeletedOCRToken"), [])
        let expired = try store.insert(image(2))
        XCTAssertTrue(try store.setRecognizedText("ExpiredOCRToken", for: expired.id))
        try execute("UPDATE entries SET last_copied_at = 0 WHERE id = '\(expired.id)'", at: url)
        XCTAssertFalse(try store.setRecognizedText("Late text", for: expired.id))
        XCTAssertEqual(try store.imagesNeedingRecognition(), [])
        XCTAssertNil(try store.recognizedText(for: expired.id))
        XCTAssertEqual(try store.entries(search: "ExpiredOCRToken"), [])
        let cleared = try store.insert(image(3))
        XCTAssertTrue(try store.setRecognizedText("ClearedOCRToken", for: cleared.id))
        try store.clear()
        XCTAssertFalse(try store.setRecognizedText("Late text", for: cleared.id))
        XCTAssertEqual(try store.entries(search: "ClearedOCRToken"), [])
        XCTAssertEqual(try rowCount("representations", at: url), 0)
        XCTAssertEqual(try rowCount("entries_search", at: url), 0)
    }

    func testRecognitionRejectsNonImagesNULAndOversizeUTF8WithoutReplacingExistingText() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ClipboardStore(databaseURL: folder.appendingPathComponent("history.sqlite"))
        let plain = try store.insert(text())
        XCTAssertFalse(try store.setRecognizedText("Not image text", for: plain.id))
        XCTAssertNil(try store.recognizedText(for: plain.id))
        let entry = try store.insert(image())
        let atLimit = String(repeating: "é", count: ClipboardStore.maximumRecognizedTextBytes / 2)
        XCTAssertTrue(try store.setRecognizedText(atLimit, for: entry.id))
        XCTAssertThrowsError(try store.setRecognizedText(atLimit + "é", for: entry.id))
        XCTAssertThrowsError(try store.setRecognizedText("Invalid\0text", for: entry.id))
        XCTAssertEqual(try store.recognizedText(for: entry.id), atLimit)
        XCTAssertEqual(try store.entries(search: "Invalid"), [])
    }

    func testBackupRestoreRetainsRecognizedAndPendingImages() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try ClipboardStore(databaseURL: folder.appendingPathComponent("source.sqlite"))
        let recognized = try source.insert(image(1))
        let pending = try source.insert(image(2))
        XCTAssertTrue(try source.setRecognizedText("RestoredOCR 日本語", for: recognized.id))
        let backup = folder.appendingPathComponent("backup.sqlite")
        try source.backup(to: backup)
        let restored = try ClipboardStore(databaseURL: folder.appendingPathComponent("restored.sqlite"))
        try restored.restore(from: backup)
        XCTAssertEqual(try restored.recognizedText(for: recognized.id), "RestoredOCR 日本語")
        XCTAssertEqual(try restored.entries(search: "restoredocr").map(\.id), [recognized.id])
        XCTAssertEqual(try restored.imagesNeedingRecognition().map(\.id), [pending.id])
        XCTAssertEqual(try restored.representations(for: recognized.id), image(1).representations)
    }

    func testLegacyRestoreValidatesBeforeMigrationAndQueuesItsImages() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try ClipboardStore(databaseURL: folder.appendingPathComponent("source.sqlite"))
        let original = try source.insert(image())
        let legacy = folder.appendingPathComponent("legacy.sqlite")
        try makeLegacyBackup(from: source, to: legacy)
        let sourceBytes = try Data(contentsOf: legacy)
        let restored = try ClipboardStore(databaseURL: folder.appendingPathComponent("restored.sqlite"))
        try restored.restore(from: legacy)
        XCTAssertEqual(try restored.imagesNeedingRecognition().map(\.id), [original.id])
        XCTAssertNil(try restored.recognizedText(for: original.id))
        XCTAssertEqual(try restored.representations(for: original.id), image().representations)
        XCTAssertEqual(try Data(contentsOf: legacy), sourceBytes)
        XCTAssertTrue(try restored.setRecognizedText("Migrated OCR", for: original.id))
        XCTAssertEqual(try restored.entries(search: "migrated").map(\.id), [original.id])

        // An extra legacy trigger must be rejected before migration can run.
        try execute("CREATE TRIGGER unexpected AFTER UPDATE ON entries BEGIN DELETE FROM representations; END", at: legacy)
        XCTAssertThrowsError(try restored.restore(from: legacy))
        XCTAssertEqual(try restored.recognizedText(for: original.id), "Migrated OCR")
        XCTAssertEqual(try restored.representations(for: original.id), image().representations)
    }

    func testOpeningLegacyLiveDatabaseMigratesWithoutLosingPayloads() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try ClipboardStore(databaseURL: folder.appendingPathComponent("source.sqlite"))
        let original = try source.insert(image())
        let legacy = folder.appendingPathComponent("legacy.sqlite")
        try makeLegacyBackup(from: source, to: legacy)
        let migrated = try ClipboardStore(databaseURL: legacy)
        XCTAssertEqual(try migrated.imagesNeedingRecognition().map(\.id), [original.id])
        XCTAssertEqual(try migrated.representations(for: original.id), image().representations)
        XCTAssertTrue(try migrated.setRecognizedText("Live migration", for: original.id))
    }

    func testMalformedRecognitionBackupsLeaveLiveHistoryUntouched() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try ClipboardStore(databaseURL: folder.appendingPathComponent("source.sqlite"))
        let image = try source.insert(image())
        _ = try source.insert(text())
        let live = try ClipboardStore(databaseURL: folder.appendingPathComponent("live.sqlite"))
        let existing = try live.insert(text())
        let malformedValues = [
            "X'FFFE'", // blob rather than text
            "CAST(X'FFFE' AS TEXT)", // invalid UTF-8
            "'prefix' || char(0) || 'suffix'",
            "replace(hex(zeroblob(131073)), '0', 'a')"
        ]
        for (index, value) in malformedValues.enumerated() {
            let backup = folder.appendingPathComponent("malformed-\(index).sqlite")
            try source.backup(to: backup)
            try execute("UPDATE entries SET recognized_text = \(value) WHERE id = '\(image.id)'", at: backup)
            XCTAssertThrowsError(try live.restore(from: backup), "Value: \(value)")
            XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        }
        let wrongKind = folder.appendingPathComponent("wrong-kind.sqlite")
        try source.backup(to: wrongKind)
        try execute("UPDATE entries SET recognized_text = 'Image text on plain text' WHERE kind = 'text'", at: wrongKind)
        XCTAssertThrowsError(try live.restore(from: wrongKind))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
        let extraTrigger = folder.appendingPathComponent("trigger.sqlite")
        try source.backup(to: extraTrigger)
        try execute("CREATE TRIGGER unexpected AFTER UPDATE ON entries BEGIN DELETE FROM representations; END", at: extraTrigger)
        XCTAssertThrowsError(try live.restore(from: extraTrigger))
        XCTAssertEqual(try live.entries().map(\.id), [existing.id])
    }
}
