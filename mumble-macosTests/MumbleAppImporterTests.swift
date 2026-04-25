import SQLite3
import XCTest
@testable import mumble_macos

/// Reads a synthesized `mumble.sqlite` to confirm the SQLite parser handles
/// the schema, NULL ports, missing tables, and skip-malformed semantics
/// without depending on the user's real Mumble installation.
final class MumbleAppImporterTests: XCTestCase {

    /// SQLite's "transient" sentinel — `sqlite3_bind_text` needs a
    /// `sqlite3_destructor_type` and the conventional way to spell
    /// `SQLITE_TRANSIENT` from Swift is this bit-pattern cast.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private var dbURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumble-app-import-test-\(UUID().uuidString).sqlite",
                                    isDirectory: false)
    }

    override func tearDown() async throws {
        if let dbURL { try? FileManager.default.removeItem(at: dbURL) }
        dbURL = nil
        try await super.tearDown()
    }

    // MARK: - Fixture builder

    /// Creates a fresh SQLite at `dbURL` with the same `servers` schema the
    /// reference client uses. Returns nothing on success, fails the test
    /// loudly on any SQLite error so the assertion in the actual test can
    /// trust its starting state.
    private func writeMumbleSchema(rows: [(name: String?, host: String?, port: Int?, username: String?, password: String?)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE `servers` (
            `id` INTEGER PRIMARY KEY AUTOINCREMENT,
            `name` TEXT,
            `hostname` TEXT,
            `port` INTEGER DEFAULT 64738,
            `username` TEXT,
            `password` TEXT,
            `url` TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)

        for row in rows {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO servers (name, hostname, port, username, password) VALUES (?, ?, ?, ?, ?)"
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)

            bindOptionalText(stmt, 1, row.name)
            bindOptionalText(stmt, 2, row.host)
            if let port = row.port {
                sqlite3_bind_int(stmt, 3, Int32(port))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bindOptionalText(stmt, 4, row.username)
            bindOptionalText(stmt, 5, row.password)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    // MARK: - Happy path

    func test_readsAllRowsInOrder() throws {
        try writeMumbleSchema(rows: [
            ("Init Main", "mumble.sh1t.space", 64738, "Fenix", "topsecret"),
            ("Pandemic", "mumble.pandemic-horde.org", 41001, "Fenix", "")
        ])

        let importer = MumbleAppImporter()
        let read = try importer.read(at: dbURL)
        XCTAssertEqual(read, [
            MumbleAppImportRow(name: "Init Main", host: "mumble.sh1t.space", port: 64738,
                               username: "Fenix", password: "topsecret"),
            MumbleAppImportRow(name: "Pandemic", host: "mumble.pandemic-horde.org", port: 41001,
                               username: "Fenix", password: "")
        ])
    }

    // MARK: - Field handling

    func test_emptyNameFallsBackToHost() throws {
        try writeMumbleSchema(rows: [(nil, "no-name.example", 64738, "u", "")])
        let read = try MumbleAppImporter().read(at: dbURL)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].name, "no-name.example")
        XCTAssertEqual(read[0].host, "no-name.example")
    }

    func test_nullPortFallsBackToDefault() throws {
        // The schema's DEFAULT 64738 only fires when the column is omitted
        // from the INSERT — explicit NULL bind stays NULL. Mirror that
        // edge case here: we want the importer to substitute 64738.
        try writeMumbleSchema(rows: [("X", "host.example", nil, "u", "")])
        let read = try MumbleAppImporter().read(at: dbURL)
        XCTAssertEqual(read[0].port, 64738)
    }

    func test_zeroPortFallsBackToDefault() throws {
        try writeMumbleSchema(rows: [("X", "host.example", 0, "u", "")])
        let read = try MumbleAppImporter().read(at: dbURL)
        XCTAssertEqual(read[0].port, 64738)
    }

    func test_skipsRowWithEmptyHostname() throws {
        try writeMumbleSchema(rows: [
            ("Empty", "", 64738, "u", ""),
            ("Good", "good.example", 64738, "u", "")
        ])
        let read = try MumbleAppImporter().read(at: dbURL)
        XCTAssertEqual(read.map(\.host), ["good.example"])
    }

    func test_skipsRowWithOutOfRangePort() throws {
        try writeMumbleSchema(rows: [
            ("Bad", "bad.example", 70000, "u", ""),
            ("Good", "good.example", 64738, "u", "")
        ])
        let read = try MumbleAppImporter().read(at: dbURL)
        XCTAssertEqual(read.map(\.host), ["good.example"])
    }

    // MARK: - Failure modes

    func test_throwsOnMissingFile() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try MumbleAppImporter().read(at: bogus)) { error in
            guard case MumbleAppImportError.fileMissing = error else {
                return XCTFail("Expected fileMissing, got \(error)")
            }
        }
    }

    func test_throwsOnNonMumbleDatabase() throws {
        // Build a SQLite with a different schema. Importer should refuse.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE wrong (id INTEGER);", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try MumbleAppImporter().read(at: dbURL)) { error in
            guard case MumbleAppImportError.noServersTable = error else {
                return XCTFail("Expected noServersTable, got \(error)")
            }
        }
    }
}
