import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A serialized, local SQLite store. Original payloads live in the database so
/// deleting or expiring a row cannot leave image files behind.
public final class ClipboardStore: @unchecked Sendable {
    public static let retentionInterval: TimeInterval = 60 * 24 * 60 * 60
    public static let maximumCaptureBytes = 64 * 1_024 * 1_024

    public let databaseURL: URL

    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private var supportsFullTextSearch = false
    private var supportsFullTextSecureDelete = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw ClipboardStoreError.invalidLocation }
        self.databaseURL = databaseURL.standardizedFileURL
        try Self.prepareDirectory(self.databaseURL.deletingLastPathComponent())
        try Self.rejectSymbolicLink(self.databaseURL)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let error = databaseError()
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try secureFiles()
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try createSchema()
            _ = try purgeExpired()
            try secureFiles()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    @discardableResult
    public func insert(_ capture: ClipboardCapture, now: Date = Date()) throws -> ClipboardEntry {
        try synchronized {
            let byteCount = try validate(capture, now: now)
            let digest = Self.digest(capture)
            let id = UUID().uuidString
            let searchDocument = Self.normalize(
                [capture.title, capture.text ?? "", capture.sourceApp, capture.sourceBundleID ?? ""]
                    .joined(separator: "\n")
            )

            var expiredCount = 0
            let storedID: String = try transaction {
                expiredCount = try purgeExpiredUnlocked(now: now)
                let existing = try prepare("SELECT id FROM entries WHERE digest = ?")
                defer { sqlite3_finalize(existing) }
                try bind(digest, at: 1, in: existing)
                let existingResult = sqlite3_step(existing)
                let existingID: String?
                if existingResult == SQLITE_ROW {
                    existingID = string(existing, 0)
                } else if existingResult == SQLITE_DONE {
                    existingID = nil
                } else {
                    throw databaseError()
                }

                let resolvedID = existingID ?? id
                let statement = try prepare("""
                    INSERT INTO entries (
                        id, digest, kind, title, preview_text, source_app, source_bundle_id,
                        created_at, last_copied_at, is_pinned, thumbnail, image_width,
                        image_height, byte_count, search_document
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    ON CONFLICT(digest) DO UPDATE SET
                        kind = excluded.kind, title = excluded.title,
                        preview_text = excluded.preview_text, source_app = excluded.source_app,
                        source_bundle_id = excluded.source_bundle_id,
                        last_copied_at = MAX(entries.last_copied_at, excluded.last_copied_at),
                        thumbnail = excluded.thumbnail, image_width = excluded.image_width,
                        image_height = excluded.image_height, byte_count = excluded.byte_count,
                        search_document = excluded.search_document
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(resolvedID, at: 1, in: statement)
                try bind(digest, at: 2, in: statement)
                try bind(capture.kind.rawValue, at: 3, in: statement)
                try bind(capture.title, at: 4, in: statement)
                try bind(capture.text, at: 5, in: statement)
                try bind(capture.sourceApp, at: 6, in: statement)
                try bind(capture.sourceBundleID, at: 7, in: statement)
                try bind(now.timeIntervalSince1970, at: 8, in: statement)
                try bind(now.timeIntervalSince1970, at: 9, in: statement)
                try bind(capture.thumbnail, at: 10, in: statement)
                try bind(capture.imageWidth, at: 11, in: statement)
                try bind(capture.imageHeight, at: 12, in: statement)
                try bind(byteCount, at: 13, in: statement)
                try bind(searchDocument, at: 14, in: statement)
                try finish(statement)

                let remove = try prepare("DELETE FROM representations WHERE entry_id = ?")
                defer { sqlite3_finalize(remove) }
                try bind(resolvedID, at: 1, in: remove)
                try finish(remove)
                let payload = try prepare("""
                    INSERT INTO representations (entry_id, position, type, data) VALUES (?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(payload) }
                for (position, representation) in capture.representations.enumerated() {
                    sqlite3_reset(payload)
                    sqlite3_clear_bindings(payload)
                    try bind(resolvedID, at: 1, in: payload)
                    try bind(position, at: 2, in: payload)
                    try bind(representation.type, at: 3, in: payload)
                    try bind(representation.data, at: 4, in: payload)
                    try finish(payload)
                }
                return resolvedID
            }
            if expiredCount > 0 { try scrubDeletedPages() }
            try secureFiles()
            guard let entry = try entry(id: storedID) else { throw ClipboardStoreError.missingEntry }
            return entry
        }
    }

    public func entries(
        search: String = "",
        kind: ClipboardKind? = nil,
        limit: Int = 200
    ) throws -> [ClipboardEntry] {
        try synchronized {
            guard limit > 0 else { return [] }
            if try purgeExpiredUnlocked(now: Date()) > 0 { try scrubDeletedPages() }
            let query = Self.normalize(search.trimmingCharacters(in: .whitespacesAndNewlines))
            let useFullTextSearch = supportsFullTextSearch && !query.isEmpty && query.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
            var conditions: [String] = []
            if kind != nil { conditions.append("kind = ?") }
            if !query.isEmpty {
                conditions.append(useFullTextSearch
                    ? "(id IN (SELECT id FROM entries_search WHERE entries_search MATCH ?) OR search_document LIKE ? ESCAPE '\\')"
                    : "search_document LIKE ? ESCAPE '\\'")
            }
            let predicate = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            let statement = try prepare("""
                SELECT \(Self.entryColumns) FROM entries\(predicate)
                ORDER BY is_pinned DESC, last_copied_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let kind {
                try bind(kind.rawValue, at: index, in: statement)
                index += 1
            }
            if !query.isEmpty {
                if useFullTextSearch {
                    // A quoted, parameter-bound phrase cannot inject FTS syntax.
                    let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
                    try bind(phrase, at: index, in: statement)
                    index += 1
                }
                let pattern = "%" + Self.escapeLike(query) + "%"
                try bind(pattern, at: index, in: statement)
                index += 1
            }
            try bind(min(limit, 10_000), at: index, in: statement)
            var result: [ClipboardEntry] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError() }
                result.append(try readEntry(statement))
            }
            return result
        }
    }

    public func representations(for id: String) throws -> [ClipboardRepresentation] {
        try synchronized {
            if try purgeExpiredUnlocked(now: Date()) > 0 { try scrubDeletedPages() }
            guard try entry(id: id) != nil else { throw ClipboardStoreError.missingEntry }
            let statement = try prepare("""
                SELECT type, data FROM representations WHERE entry_id = ? ORDER BY position ASC
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, in: statement)
            var result: [ClipboardRepresentation] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError() }
                result.append(ClipboardRepresentation(type: string(statement, 0), data: data(statement, 1) ?? Data()))
            }
            return result
        }
    }

    public func setPinned(id: String, pinned: Bool) throws {
        try synchronized {
            let statement = try prepare("UPDATE entries SET is_pinned = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(pinned ? 1 : 0, at: 1, in: statement)
            try bind(id, at: 2, in: statement)
            try finish(statement)
            guard sqlite3_changes(database) > 0 else { throw ClipboardStoreError.missingEntry }
            try secureFiles()
        }
    }

    /// Reusing an item is a new copy, even when the monitor ignores our own
    /// pasteboard write. Touch its retention date without rewriting its formats.
    public func recordCopy(id: String, now: Date = Date()) throws {
        try synchronized {
            guard now.timeIntervalSince1970.isFinite else {
                throw ClipboardStoreError.invalidCapture("The copy date is invalid.")
            }
            if try purgeExpiredUnlocked(now: now) > 0 { try scrubDeletedPages() }
            let statement = try prepare("UPDATE entries SET last_copied_at = MAX(last_copied_at, ?) WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(now.timeIntervalSince1970, at: 1, in: statement)
            try bind(id, at: 2, in: statement)
            try finish(statement)
            guard sqlite3_changes(database) > 0 else { throw ClipboardStoreError.missingEntry }
            try secureFiles()
        }
    }

    public func delete(id: String) throws {
        try synchronized {
            let statement = try prepare("DELETE FROM entries WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, in: statement)
            try finish(statement)
            try scrubDeletedPages()
        }
    }

    public func clear() throws {
        try synchronized {
            try execute("DELETE FROM entries")
            try scrubDeletedPages()
        }
    }

    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> Int {
        try synchronized {
            guard now.timeIntervalSince1970.isFinite else {
                throw ClipboardStoreError.invalidCapture("The copy date is invalid.")
            }
            let deleted = try purgeExpiredUnlocked(now: now)
            if deleted > 0 { try scrubDeletedPages() }
            return deleted
        }
    }

    /// SQLite's online backup captures a consistent database, including live WAL
    /// changes. The previous managed snapshot is replaced only after completion.
    public func backup(to url: URL) throws {
        try synchronized {
            guard url.isFileURL else { throw ClipboardStoreError.invalidLocation }
            let destination = url.standardizedFileURL
            let livePath = databaseURL.resolvingSymlinksInPath().path
            let reservedPaths = ["", "-wal", "-shm", "-journal"].map { livePath + $0 }
            guard !reservedPaths.contains(destination.resolvingSymlinksInPath().path) else {
                throw ClipboardStoreError.invalidLocation
            }
            try Self.prepareDirectory(destination.deletingLastPathComponent(), secureExisting: false)
            try Self.rejectSymbolicLink(destination)
            _ = try purgeExpired()
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".clipboard-backup-\(UUID().uuidString).sqlite")
            var target: OpaquePointer?
            var targetIsOpen = false
            defer {
                if targetIsOpen { sqlite3_close(target) }
                try? FileManager.default.removeItem(at: temporary)
            }
            guard sqlite3_open_v2(temporary.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                let message = target.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the backup."
                if target != nil { sqlite3_close(target) }
                throw ClipboardStoreError.database(message)
            }
            targetIsOpen = true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard let transfer = sqlite3_backup_init(target, "main", database, "main") else {
                throw ClipboardStoreError.database(String(cString: sqlite3_errmsg(target)))
            }
            let result = sqlite3_backup_step(transfer, -1)
            let finishResult = sqlite3_backup_finish(transfer)
            guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
                throw ClipboardStoreError.database(String(cString: sqlite3_errmsg(target)))
            }
            // Export a self-contained file; reading a backup must not require
            // writable WAL sidecars next to a user-selected restore source.
            guard sqlite3_exec(target, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK else {
                throw ClipboardStoreError.database("The completed backup could not be made self-contained.")
            }
            guard sqlite3_close(target) == SQLITE_OK else {
                throw ClipboardStoreError.database("The completed backup could not be closed.")
            }
            targetIsOpen = false
            // rename(2), used by FileManager's replacement, is atomic on this volume.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    /// Validate and clean a private staging database before replacing live
    /// history. SQLite's backup transaction leaves live data intact on failure.
    public func restore(from url: URL, now: Date = Date()) throws {
        try synchronized {
            guard url.isFileURL, now.timeIntervalSince1970.isFinite else {
                throw ClipboardStoreError.invalidLocation
            }
            // Probe sidecars beside the exact file SQLite will open. Otherwise
            // a symlink alias could hide its target's active WAL or hot journal.
            let sourceURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let livePath = databaseURL.resolvingSymlinksInPath().path
            let reservedPaths = ["", "-wal", "-shm", "-journal"].map { livePath + $0 }
            guard !reservedPaths.contains(sourceURL.resolvingSymlinksInPath().path) else {
                throw ClipboardStoreError.invalidLocation
            }
            guard !FileManager.default.fileExists(atPath: sourceURL.path + "-wal") else {
                throw ClipboardStoreError.database("Select a completed backup, rather than a database with an active WAL file.")
            }
            guard !FileManager.default.fileExists(atPath: sourceURL.path + "-journal") else {
                throw ClipboardStoreError.database("Select a completed backup, rather than a database with a pending rollback journal.")
            }
            var source: OpaquePointer?
            // Older snapshots can retain the WAL-mode header despite containing
            // all committed pages. Immutable read-only mode avoids opening or
            // creating sidecars and never changes the user's selected file.
            let sourceURI = sourceURL.absoluteString + "?mode=ro&immutable=1"
            guard sqlite3_open_v2(sourceURI, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if source != nil { sqlite3_close(source) }
                throw ClipboardStoreError.database("The selected backup could not be opened.")
            }
            defer { sqlite3_close(source) }
            sqlite3_busy_timeout(source, 5_000)

            let temporary = databaseURL.deletingLastPathComponent()
                .appendingPathComponent(".clipboard-restore-\(UUID().uuidString).sqlite")
            let stage = try ClipboardStore(databaseURL: temporary)
            defer {
                if let stageDatabase = stage.database {
                    sqlite3_close_v2(stageDatabase)
                    stage.database = nil
                }
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    // Error paths preserve the original restore error. unlink does
                    // not create a Swift error when SQLite already removed a sidecar.
                    _ = (temporary.path + suffix).withCString { unlink($0) }
                }
            }
            let expectedSchema = try stage.schemaDefinitions()
            // The staging connection has no concurrent readers. SQLite backup
            // can replace it without carrying over its previous WAL state.
            try stage.execute("PRAGMA journal_mode = DELETE")
            try Self.transferDatabase(from: source, to: stage.database, phase: "staging")
            try stage.execute("PRAGMA journal_mode = WAL")
            try stage.validateRestore(expectedSchema: expectedSchema)
            try stage.createSchema()
            _ = try stage.purgeExpired(now: now)
            try Self.transferDatabase(from: stage.database, to: database, phase: "restore")
            try scrubDeletedPages()
            if let stageDatabase = stage.database {
                guard sqlite3_close(stageDatabase) == SQLITE_OK else {
                    throw ClipboardStoreError.database("The staged restore could not be closed.")
                }
                stage.database = nil
            }
            // SQLite removes its own WAL/SHM/journal files during close. Treat
            // ENOENT as success; report permission and other actual failures.
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try Self.removeFileIfPresent(atPath: temporary.path + suffix)
            }
        }
    }

    private static func transferDatabase(from source: OpaquePointer?, to target: OpaquePointer?, phase: String) throws {
        guard let transfer = sqlite3_backup_init(target, "main", source, "main") else {
            throw ClipboardStoreError.database("The SQLite backup could not be initialized.")
        }
        let result = sqlite3_backup_step(transfer, -1)
        let finishResult = sqlite3_backup_finish(transfer)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            let sourceMessage = source.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            let targetMessage = target.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            let extendedCode = sqlite3_extended_errcode(target)
            throw ClipboardStoreError.database("The SQLite \(phase) could not be completed (\(result)/\(finishResult)/\(extendedCode); source: \(sourceMessage); destination: \(targetMessage)).")
        }
    }

    private func schemaDefinitions() throws -> [String: String] {
        let statement = try prepare("SELECT type, name, sql FROM sqlite_schema ORDER BY name")
        defer { sqlite3_finalize(statement) }
        var definitions: [String: String] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return definitions }
            guard result == SQLITE_ROW else { throw databaseError() }
            let key = string(statement, 0) + ":" + string(statement, 1)
            // Compare structure to a schema created by this version of the app.
            // This also rejects extra triggers or externally modified tables.
            definitions[key] = optionalString(statement, 2) ?? ""
        }
    }

    private func validateRestore(expectedSchema: [String: String]) throws {
        guard try schemaDefinitions() == expectedSchema else {
            throw ClipboardStoreError.database("The selected file is not a compatible Jutilities backup.")
        }
        let version = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) == 1 else {
            throw ClipboardStoreError.database("The backup has an unsupported schema version.")
        }
        let integrity = try prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW, string(integrity, 0) == "ok",
              sqlite3_step(integrity) == SQLITE_DONE else {
            throw ClipboardStoreError.database("The selected backup failed its integrity check.")
        }
        let foreignKeys = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreignKeys) }
        guard sqlite3_step(foreignKeys) == SQLITE_DONE else {
            throw ClipboardStoreError.database("The selected backup has missing clipboard payloads.")
        }
        let rows = try prepare("""
            SELECT COUNT(*) FROM entries WHERE
                typeof(id) != 'text' OR length(id) = 0 OR typeof(digest) != 'text' OR
                kind NOT IN ('text', 'link', 'image') OR typeof(title) != 'text' OR
                length(CAST(title AS BLOB)) > 16384 OR typeof(source_app) != 'text' OR
                length(CAST(source_app AS BLOB)) > 4096 OR
                typeof(created_at) NOT IN ('integer', 'real') OR
                typeof(last_copied_at) NOT IN ('integer', 'real') OR
                abs(created_at) > 1000000000000 OR abs(last_copied_at) > 1000000000000 OR
                is_pinned NOT IN (0, 1) OR byte_count < 0 OR byte_count > 67108864 OR
                (thumbnail IS NOT NULL AND typeof(thumbnail) != 'blob') OR
                (image_width IS NOT NULL AND (image_width <= 0 OR image_width > 1000000)) OR
                (image_height IS NOT NULL AND (image_height <= 0 OR image_height > 1000000)) OR
                (preview_text IS NOT NULL AND length(CAST(preview_text AS BLOB)) > 67108864) OR
                (SELECT COUNT(*) FROM representations WHERE entry_id = entries.id) NOT BETWEEN 1 AND 128 OR
                COALESCE(length(thumbnail), 0) +
                    (SELECT COALESCE(SUM(length(data)), 0) FROM representations WHERE entry_id = entries.id) > 67108864
            """)
        defer { sqlite3_finalize(rows) }
        guard sqlite3_step(rows) == SQLITE_ROW, sqlite3_column_int64(rows, 0) == 0 else {
            throw ClipboardStoreError.database("The backup contains invalid clipboard items.")
        }
        let formats = try prepare("""
            SELECT COUNT(*) FROM representations WHERE typeof(type) != 'text' OR
                length(CAST(type AS BLOB)) NOT BETWEEN 1 AND 1024 OR typeof(data) != 'blob' OR
                typeof(position) != 'integer' OR position < 0
            """)
        defer { sqlite3_finalize(formats) }
        guard sqlite3_step(formats) == SQLITE_ROW, sqlite3_column_int64(formats, 0) == 0 else {
            throw ClipboardStoreError.database("The backup contains invalid clipboard formats.")
        }
        if supportsFullTextSearch {
            try execute("INSERT INTO entries_search(entries_search) VALUES('integrity-check')")
        }
    }

    private static let entryColumns = """
        id, kind, title, preview_text, source_app, source_bundle_id, created_at,
        last_copied_at, is_pinned, thumbnail, image_width, image_height, byte_count
        """

    private func createSchema() throws {
        let versionStatement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else { throw databaseError() }
        let version = Int(sqlite3_column_int(versionStatement, 0))
        guard version == 0 || version == 1 else { throw ClipboardStoreError.unsupportedSchema(version) }
        try execute("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY NOT NULL,
                digest TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('text', 'link', 'image')),
                title TEXT NOT NULL,
                preview_text TEXT,
                source_app TEXT NOT NULL,
                source_bundle_id TEXT,
                created_at REAL NOT NULL,
                last_copied_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                thumbnail BLOB,
                image_width INTEGER,
                image_height INTEGER,
                byte_count INTEGER NOT NULL,
                search_document TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS representations (
                entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (entry_id, position)
            );
            CREATE INDEX IF NOT EXISTS entries_recency ON entries(is_pinned DESC, last_copied_at DESC);
            CREATE INDEX IF NOT EXISTS entries_expiry ON entries(last_copied_at);
            PRAGMA user_version = 1;
            """)
        do {
            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS entries_search
                USING fts5(id UNINDEXED, document, tokenize='unicode61 remove_diacritics 2');
                """)
            supportsFullTextSearch = true
        } catch {
            // SQLite builds without FTS5 still provide safe Unicode substring search.
            supportsFullTextSearch = false
        }
        if supportsFullTextSearch {
            try execute("""
                CREATE TRIGGER IF NOT EXISTS entries_insert AFTER INSERT ON entries BEGIN
                    INSERT INTO entries_search(id, document) VALUES(new.id, new.search_document);
                END;
                CREATE TRIGGER IF NOT EXISTS entries_delete AFTER DELETE ON entries BEGIN
                    DELETE FROM entries_search WHERE id = old.id;
                END;
                CREATE TRIGGER IF NOT EXISTS entries_update AFTER UPDATE OF search_document ON entries BEGIN
                    DELETE FROM entries_search WHERE id = old.id;
                    INSERT INTO entries_search(id, document) VALUES(new.id, new.search_document);
                END;
                INSERT INTO entries_search(id, document)
                SELECT id, search_document FROM entries
                WHERE id NOT IN (SELECT id FROM entries_search);
                """)
            do {
                try execute("INSERT INTO entries_search(entries_search, rank) VALUES('secure-delete', 1)")
                supportsFullTextSecureDelete = true
            } catch {
                supportsFullTextSecureDelete = false
            }
        }
    }

    private func purgeExpiredUnlocked(now: Date) throws -> Int {
        let statement = try prepare("DELETE FROM entries WHERE last_copied_at <= ?")
        defer { sqlite3_finalize(statement) }
        try bind(now.timeIntervalSince1970 - Self.retentionInterval, at: 1, in: statement)
        try finish(statement)
        return Int(sqlite3_changes(database))
    }

    private func scrubDeletedPages() throws {
        if supportsFullTextSearch && !supportsFullTextSecureDelete {
            // Older FTS5 builds retain deleted token segments until they merge.
            try execute("INSERT INTO entries_search(entries_search) VALUES('optimize')")
        }
        // Checkpointing prevents deleted payloads remaining in old WAL frames.
        let status = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard status == SQLITE_OK else { throw databaseError() }
        try secureFiles()
    }

    private func entry(id: String) throws -> ClipboardEntry? {
        let statement = try prepare("SELECT \(Self.entryColumns) FROM entries WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try readEntry(statement)
        case SQLITE_DONE: return nil
        default: throw databaseError()
        }
    }

    private func readEntry(_ statement: OpaquePointer) throws -> ClipboardEntry {
        guard let kind = ClipboardKind(rawValue: string(statement, 1)) else {
            throw ClipboardStoreError.database("A clipboard row contains an invalid kind.")
        }
        return ClipboardEntry(
            id: string(statement, 0), kind: kind, title: string(statement, 2),
            previewText: optionalString(statement, 3), sourceApp: string(statement, 4),
            sourceBundleID: optionalString(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            isPinned: sqlite3_column_int(statement, 8) != 0, thumbnail: data(statement, 9),
            imageWidth: integer(statement, 10), imageHeight: integer(statement, 11),
            byteCount: Int(sqlite3_column_int64(statement, 12))
        )
    }

    private func validate(_ capture: ClipboardCapture, now: Date) throws -> Int {
        guard now.timeIntervalSince1970.isFinite else {
            throw ClipboardStoreError.invalidCapture("The copy date is invalid.")
        }
        guard !capture.representations.isEmpty, capture.representations.count <= 128 else {
            throw ClipboardStoreError.invalidCapture("The item has an invalid number of formats.")
        }
        guard capture.title.utf8.count <= 16_384,
              capture.sourceApp.utf8.count <= 4_096,
              (capture.sourceBundleID?.utf8.count ?? 0) <= 4_096,
              !(capture.title.contains("\0") || capture.sourceApp.contains("\0") || (capture.sourceBundleID?.contains("\0") ?? false)) else {
            throw ClipboardStoreError.invalidCapture("The item metadata is invalid.")
        }
        for dimension in [capture.imageWidth, capture.imageHeight].compactMap({ $0 }) {
            guard dimension > 0, dimension <= 1_000_000 else {
                throw ClipboardStoreError.invalidCapture("The image dimensions are invalid.")
            }
        }
        var total = capture.thumbnail?.count ?? 0
        for representation in capture.representations {
            guard !representation.type.isEmpty,
                  representation.type.utf8.count <= 1_024,
                  !representation.type.contains("\0"),
                  representation.data.count <= Self.maximumCaptureBytes - min(total, Self.maximumCaptureBytes) else {
                throw ClipboardStoreError.invalidCapture("A clipboard format is invalid or exceeds 64 MB.")
            }
            total += representation.data.count
        }
        guard total <= Self.maximumCaptureBytes,
              (capture.text?.utf8.count ?? 0) <= Self.maximumCaptureBytes else {
            throw ClipboardStoreError.invalidCapture("The item exceeds 64 MB.")
        }
        return total
    }

    private static func digest(_ capture: ClipboardCapture) -> String {
        var hasher = SHA256()
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        append(Data(capture.kind.rawValue.utf8))
        let representations = capture.representations.sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            return $0.data.lexicographicallyPrecedes($1.data)
        }
        for representation in representations {
            append(Data(representation.type.utf8))
            append(representation.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func prepareDirectory(_ url: URL, secureExisting: Bool = true) throws {
        let alreadyExists = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !alreadyExists || secureExisting {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private static func rejectSymbolicLink(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ClipboardStoreError.invalidLocation
        }
    }

    private func secureFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                } catch {
                    // Another SQLite connection can remove a sidecar between
                    // stat and chmod. A missing primary database is still an error.
                    guard !suffix.isEmpty, Self.isMissingFile(error) else { throw error }
                }
            }
        }
    }

    private static func removeFileIfPresent(atPath path: String) throws {
        guard path.withCString({ unlink($0) }) != 0 else { return }
        let failure = errno
        guard failure != ENOENT else { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: path])
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return failure.code == Int(ENOENT) }
        if failure.domain == NSCocoaErrorDomain {
            return failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError
        }
        return false
    }

    private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw databaseError()
        }
        return statement
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        let status: Int32
        if let value {
            status = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transient) }
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Data?, at index: Int32, in statement: OpaquePointer) throws {
        let status: Int32
        if let value {
            if value.isEmpty {
                status = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) throws {
        let status = value.map { sqlite3_bind_int64(statement, index, Int64($0)) } ?? sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw databaseError() }
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func optionalString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column)
    }

    private func integer(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }

    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: length)
    }

    private func databaseError() -> ClipboardStoreError {
        ClipboardStoreError.database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "The database is unavailable.")
    }
}
