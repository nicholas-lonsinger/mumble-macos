import Foundation
import OSLog
import SQLite3

/// One row read from the reference Mumble client's `mumble.sqlite` `servers`
/// table. Schema (from a live database):
///
///     CREATE TABLE `servers` (
///         `id`       INTEGER PRIMARY KEY AUTOINCREMENT,
///         `name`     TEXT,
///         `hostname` TEXT,
///         `port`     INTEGER DEFAULT 64738,
///         `username` TEXT,
///         `password` TEXT,
///         `url`      TEXT
///     );
struct MumbleAppImportRow: Equatable, Sendable {
    let name: String
    let host: String
    let port: UInt16
    let username: String
    /// May be empty — the reference client stores blank passwords as empty
    /// strings, not NULL.
    let password: String
}

enum MumbleAppImportError: Error, LocalizedError {
    case fileMissing(URL)
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case noServersTable

    var errorDescription: String? {
        switch self {
        case .fileMissing(let url):
            return "Couldn't find mumble.sqlite at \(url.path)."
        case .openFailed(let msg):
            return "Couldn't open mumble.sqlite: \(msg)"
        case .prepareFailed(let msg):
            return "Couldn't read the servers table: \(msg)"
        case .stepFailed(let msg):
            return "Couldn't iterate the servers table: \(msg)"
        case .noServersTable:
            return "This SQLite file isn't a Mumble database (no `servers` table)."
        }
    }
}

/// Reads the reference Mumble client's bookmarks out of a `mumble.sqlite`
/// file. Read-only, single-pass. We open via the system libsqlite3 (Swift
/// imports `SQLite3` — no extra linking, no vendored copy).
struct MumbleAppImporter: Sendable {
    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "mumble-app-import")

    /// SQLite's `transient` destructor sentinel. Required by the
    /// `sqlite3_bind_*` family but unused here (we don't bind any
    /// parameters); kept for completeness in case the API grows.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    /// Defensive cap for any single column the importer pulls in. Real
    /// Mumble servers have hostnames and usernames well under 1 KB; an
    /// entry above this limit is almost certainly garbage from a
    /// corrupted / hand-crafted database, and we'd rather skip it than
    /// land a multi-megabyte string in the keychain or `Servers.json`.
    private static let maxFieldLength = 4096

    /// Reads `mumble.sqlite` at `url` and returns one row per `servers`
    /// entry. Skips rows with empty hostname or non-positive port — the
    /// reference client occasionally accumulates broken rows from its own
    /// crash recovery and we don't want to surface them as bookmarks.
    func read(at url: URL) throws -> [MumbleAppImportRow] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MumbleAppImportError.fileMissing(url)
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        )
        defer { if let db { sqlite3_close(db) } }
        guard openResult == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw MumbleAppImportError.openFailed(msg)
        }

        // Confirm the schema before we trust the file. A non-Mumble SQLite
        // (or a corrupted one) would otherwise produce confusing messages.
        if !Self.tableExists("servers", in: db) {
            throw MumbleAppImportError.noServersTable
        }

        var stmt: OpaquePointer?
        let sql = "SELECT name, hostname, port, username, password FROM servers ORDER BY id"
        let prepResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard prepResult == SQLITE_OK, let stmt else {
            throw MumbleAppImportError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        var rows: [MumbleAppImportRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw MumbleAppImportError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
            let name = Self.stringColumn(stmt, 0) ?? ""
            let host = Self.stringColumn(stmt, 1) ?? ""
            // Schema default is 64738; treat NULL or 0 as "use the default"
            // so a row migrated from an older Mumble doesn't silently
            // become port 0 (which would never connect).
            let portRaw = Int(sqlite3_column_int(stmt, 2))
            let portIsNull = sqlite3_column_type(stmt, 2) == SQLITE_NULL
            let port: UInt16
            if portIsNull || portRaw <= 0 {
                port = 64738
            } else if portRaw > Int(UInt16.max) {
                continue // skip nonsense ports rather than mod into range
            } else {
                port = UInt16(portRaw)
            }
            let username = Self.stringColumn(stmt, 3) ?? ""
            let password = Self.stringColumn(stmt, 4) ?? ""

            guard !host.isEmpty else { continue }
            // Skip rows with absurd field lengths — see `maxFieldLength`.
            if name.count > Self.maxFieldLength
                || host.count > Self.maxFieldLength
                || username.count > Self.maxFieldLength
                || password.count > Self.maxFieldLength {
                Self.log.warning("Skipping row with oversized field (host=\(host.prefix(64), privacy: .public)…)")
                continue
            }
            rows.append(MumbleAppImportRow(
                name: name.isEmpty ? host : name,
                host: host,
                port: port,
                username: username,
                password: password
            ))
        }
        Self.log.info("Read \(rows.count, privacy: .public) rows from \(url.lastPathComponent, privacy: .public)")
        return rows
    }

    // MARK: - Helpers

    private static func tableExists(_ name: String, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func stringColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }
}
