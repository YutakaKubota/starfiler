import Foundation
import OSLog
import SQLite3

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "StateDB")

// MARK: - Protocol

protocol SyncStateStoring: Sendable {
    func open() async throws
    func close() async
    func upsertFileState(_ state: SyncFileState) async throws
    func deleteFileState(relativePath: String, peerID: SyncPeerID) async throws
    func getFileState(relativePath: String, peerID: SyncPeerID) async throws -> SyncFileState?
    func getAllFileStates(for peerID: SyncPeerID) async throws -> [SyncFileState]
    func getModifiedSince(date: Date, peerID: SyncPeerID) async throws -> [SyncFileState]
    func getCurrentSyncVersion(for peerID: SyncPeerID) async throws -> UInt64
    func incrementSyncVersion(for peerID: SyncPeerID) async throws -> UInt64
}

// MARK: - File State Model

struct SyncFileState: Sendable {
    let relativePath: String
    let peerID: SyncPeerID
    let isDirectory: Bool
    let size: Int64?
    let contentModificationDate: Date?
    let contentHash: String?
    let lastSyncDate: Date
    let syncVersion: UInt64
    let isDeleted: Bool

    init(
        relativePath: String,
        peerID: SyncPeerID,
        isDirectory: Bool = false,
        size: Int64? = nil,
        contentModificationDate: Date? = nil,
        contentHash: String? = nil,
        lastSyncDate: Date = Date(),
        syncVersion: UInt64 = 0,
        isDeleted: Bool = false
    ) {
        self.relativePath = relativePath
        self.peerID = peerID
        self.isDirectory = isDirectory
        self.size = size
        self.contentModificationDate = contentModificationDate
        self.contentHash = contentHash
        self.lastSyncDate = lastSyncDate
        self.syncVersion = syncVersion
        self.isDeleted = isDeleted
    }
}

// MARK: - SQLite Database

actor SyncStateDatabase: SyncStateStoring {
    private var db: OpaquePointer?
    private let dbURL: URL

    init(dbURL: URL? = nil) {
        if let dbURL {
            self.dbURL = dbURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.nilone.starfiler"
            self.dbURL = appSupport
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("SyncState.db")
        }
    }

    func open() async throws {
        let directory = dbURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            let errorMessage = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SyncStateDatabaseError.openFailed(errorMessage)
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS sync_file_state (
                relative_path TEXT NOT NULL,
                peer_id TEXT NOT NULL,
                is_directory INTEGER NOT NULL DEFAULT 0,
                size INTEGER,
                content_modification_date REAL,
                content_hash TEXT,
                last_sync_date REAL NOT NULL,
                sync_version INTEGER NOT NULL DEFAULT 0,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (relative_path, peer_id)
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS sync_version_counter (
                peer_id TEXT PRIMARY KEY,
                current_version INTEGER NOT NULL DEFAULT 0
            )
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_sync_file_state_peer ON sync_file_state(peer_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_sync_file_state_version ON sync_file_state(sync_version)")

        logger.info("Opened sync state database at \(self.dbURL.path, privacy: .public)")
    }

    func close() async {
        if let db {
            sqlite3_close(db)
            self.db = nil
            logger.info("Closed sync state database")
        }
    }

    func upsertFileState(_ state: SyncFileState) async throws {
        let sql = """
            INSERT INTO sync_file_state (relative_path, peer_id, is_directory, size, content_modification_date, content_hash, last_sync_date, sync_version, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(relative_path, peer_id) DO UPDATE SET
                is_directory = excluded.is_directory,
                size = excluded.size,
                content_modification_date = excluded.content_modification_date,
                content_hash = excluded.content_hash,
                last_sync_date = excluded.last_sync_date,
                sync_version = excluded.sync_version,
                is_deleted = excluded.is_deleted
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (state.relativePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (state.peerID.rawValue.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, state.isDirectory ? 1 : 0)
        if let size = state.size {
            sqlite3_bind_int64(stmt, 4, size)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let date = state.contentModificationDate {
            sqlite3_bind_double(stmt, 5, date.timeIntervalSinceReferenceDate)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let hash = state.contentHash {
            sqlite3_bind_text(stmt, 6, (hash as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, state.lastSyncDate.timeIntervalSinceReferenceDate)
        sqlite3_bind_int64(stmt, 8, Int64(state.syncVersion))
        sqlite3_bind_int(stmt, 9, state.isDeleted ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    func deleteFileState(relativePath: String, peerID: SyncPeerID) async throws {
        let sql = "DELETE FROM sync_file_state WHERE relative_path = ? AND peer_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (relativePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (peerID.rawValue.uuidString as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    func getFileState(relativePath: String, peerID: SyncPeerID) async throws -> SyncFileState? {
        let sql = "SELECT * FROM sync_file_state WHERE relative_path = ? AND peer_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (relativePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (peerID.rawValue.uuidString as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return readFileState(from: stmt)
    }

    func getAllFileStates(for peerID: SyncPeerID) async throws -> [SyncFileState] {
        let sql = "SELECT * FROM sync_file_state WHERE peer_id = ? AND is_deleted = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (peerID.rawValue.uuidString as NSString).utf8String, -1, nil)

        var results: [SyncFileState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileState(from: stmt))
        }
        return results
    }

    func getModifiedSince(date: Date, peerID: SyncPeerID) async throws -> [SyncFileState] {
        let sql = "SELECT * FROM sync_file_state WHERE peer_id = ? AND last_sync_date > ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (peerID.rawValue.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, date.timeIntervalSinceReferenceDate)

        var results: [SyncFileState] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileState(from: stmt))
        }
        return results
    }

    func getCurrentSyncVersion(for peerID: SyncPeerID) async throws -> UInt64 {
        let sql = "SELECT current_version FROM sync_version_counter WHERE peer_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (peerID.rawValue.uuidString as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return UInt64(sqlite3_column_int64(stmt, 0))
    }

    func incrementSyncVersion(for peerID: SyncPeerID) async throws -> UInt64 {
        let sql = """
            INSERT INTO sync_version_counter (peer_id, current_version)
            VALUES (?, 1)
            ON CONFLICT(peer_id) DO UPDATE SET current_version = current_version + 1
        """
        try execute(sql, bindings: [.text(peerID.rawValue.uuidString)])

        return try await getCurrentSyncVersion(for: peerID)
    }

    // MARK: - Private

    private func readFileState(from stmt: OpaquePointer?) -> SyncFileState {
        let relativePath = String(cString: sqlite3_column_text(stmt, 0))
        let peerIDString = String(cString: sqlite3_column_text(stmt, 1))
        let isDirectory = sqlite3_column_int(stmt, 2) != 0
        let size: Int64? = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_int64(stmt, 3) : nil
        let modDate: Date? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            : nil
        let hash: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 5))
            : nil
        let lastSyncDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        let syncVersion = UInt64(sqlite3_column_int64(stmt, 7))
        let isDeleted = sqlite3_column_int(stmt, 8) != 0

        return SyncFileState(
            relativePath: relativePath,
            peerID: SyncPeerID(rawValue: UUID(uuidString: peerIDString) ?? UUID()),
            isDirectory: isDirectory,
            size: size,
            contentModificationDate: modDate,
            contentHash: hash,
            lastSyncDate: lastSyncDate,
            syncVersion: syncVersion,
            isDeleted: isDeleted
        )
    }

    private enum SQLiteBinding {
        case text(String)
        case int64(Int64)
        case double(Double)
        case null
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        for (index, binding) in bindings.enumerated() {
            let col = Int32(index + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(stmt, col, (value as NSString).utf8String, -1, nil)
            case .int64(let value):
                sqlite3_bind_int64(stmt, col, value)
            case .double(let value):
                sqlite3_bind_double(stmt, col, value)
            case .null:
                sqlite3_bind_null(stmt, col)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SyncStateDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func lastErrorMessage() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
    }
}

// MARK: - Errors

enum SyncStateDatabaseError: Error, Sendable, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open sync state database: \(msg)"
        case .queryFailed(let msg): return "Database query failed: \(msg)"
        }
    }
}
