import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    deinit { sqlite3_close(pointer) }
}

public actor SQLiteStore {
    private let database: SQLiteHandle

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var openedDatabase: OpaquePointer?
        guard sqlite3_open(url.path, &openedDatabase) == SQLITE_OK else { throw StoreError.openFailed }
        do {
            try Self.migrate(database: openedDatabase)
        } catch {
            sqlite3_close(openedDatabase)
            throw error
        }
        database = SQLiteHandle(pointer: openedDatabase)
    }

    public func save(scan: ScanSummary) throws {
        try execute("BEGIN TRANSACTION")
        do {
            try execute("DELETE FROM plugins")
            for plugin in scan.plugins {
                let sql = "INSERT INTO plugins(id,name,manufacturer,version,format,bytes,health,license,official_url,scanned_at,bundle_path) VALUES(?,?,?,?,?,?,?,?,?,?,?)"
                try bindAndExecute(sql, [plugin.id.uuidString, plugin.name, plugin.manufacturer ?? NSNull(), plugin.version ?? NSNull(), plugin.format.rawValue, plugin.totalBytes, plugin.health.rawValue, plugin.license.rawValue, plugin.officialURL?.absoluteString ?? NSNull(), plugin.scannedAt.timeIntervalSince1970, plugin.bundleURL?.path ?? NSNull()])
            }
            try bindAndExecute("INSERT OR REPLACE INTO app_metadata(key,value) VALUES('last_scan',?)", [scan.scannedAt.timeIntervalSince1970])
            try execute("COMMIT")
            LogicPluginSweeperLog.database.info("Saved scan history: \(scan.plugins.count, privacy: .public) plugins")
        } catch { _ = try? execute("ROLLBACK"); throw error }
    }

    public func loadPlugins() throws -> [PluginRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, "SELECT id,name,manufacturer,version,format,bytes,health,license,official_url,scanned_at,bundle_path FROM plugins ORDER BY name", -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var result: [PluginRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = text(statement, 0), let id = UUID(uuidString: idString), let name = text(statement, 1), let format = PluginFormat(rawValue: text(statement, 4) ?? "Unknown") else { continue }
            let byteCount = sqlite3_column_int64(statement, 5)
            result.append(PluginRecord(id: id, name: name, manufacturer: text(statement, 2), version: text(statement, 3), format: format, files: [], health: PluginHealth(rawValue: text(statement, 6) ?? "notChecked") ?? .notChecked, license: LicenseStatus(rawValue: text(statement, 7) ?? "unknown") ?? .unknown, officialURL: text(statement, 8).flatMap(URL.init(string:)), scannedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)), bundleURL: text(statement, 10).map { URL(fileURLWithPath: $0) }, measuredBytes: byteCount, fileCount: 0))
        }
        return result
    }

    public func loadLastScan() throws -> Date? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, "SELECT value FROM app_metadata WHERE key='last_scan'", -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func saveRemoval(_ record: RemovalRecord) throws {
        let payload = try JSONEncoder().encode(record)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, "INSERT OR REPLACE INTO removal_records(id,payload) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        _ = record.id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) }
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed }
    }

    public func loadRemovals() throws -> [RemovalRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, "SELECT payload FROM removal_records", -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var records: [RemovalRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let record = try? JSONDecoder().decode(RemovalRecord.self, from: data) { records.append(record) }
        }
        return records.sorted { $0.removedAt < $1.removedAt }
    }

    public func deleteRemoval(id: UUID) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, "DELETE FROM removal_records WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        _ = id.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed }
    }

    private static func migrate(database: OpaquePointer?) throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)", database: database)
        try execute("CREATE TABLE IF NOT EXISTS plugins(id TEXT PRIMARY KEY,name TEXT NOT NULL,manufacturer TEXT,version TEXT,format TEXT NOT NULL,bytes INTEGER NOT NULL,health TEXT NOT NULL,license TEXT NOT NULL,official_url TEXT,scanned_at REAL NOT NULL,bundle_path TEXT)", database: database)
        _ = try? execute("ALTER TABLE plugins ADD COLUMN bundle_path TEXT", database: database)
        try execute("CREATE TABLE IF NOT EXISTS removal_history(id TEXT PRIMARY KEY,plugin_name TEXT NOT NULL,original_paths TEXT NOT NULL,quarantine_url TEXT NOT NULL,bytes INTEGER NOT NULL,removed_at REAL NOT NULL,restored_at REAL)", database: database)
        try execute("CREATE TABLE IF NOT EXISTS removal_records(id TEXT PRIMARY KEY,payload BLOB NOT NULL)", database: database)
        try execute("CREATE TABLE IF NOT EXISTS app_metadata(key TEXT PRIMARY KEY,value REAL NOT NULL)", database: database)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database.pointer, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.queryFailed }
    }

    private static func execute(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.queryFailed }
    }

    private func bindAndExecute(_ sql: String, _ values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value { case let string as String: sqlite3_bind_text(statement, position, string, -1, sqliteTransient); case let number as Int64: sqlite3_bind_int64(statement, position, number); case let number as Double: sqlite3_bind_double(statement, position, number); default: sqlite3_bind_null(statement, position) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
    public enum StoreError: Error { case openFailed, queryFailed }
}
