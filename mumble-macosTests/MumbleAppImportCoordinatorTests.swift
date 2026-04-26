import SQLite3
import XCTest
@testable import mumble_macos

/// End-to-end tests for `MumbleAppImportCoordinator`. They wire a real
/// `MumbleAppImporter`, an isolated `ServerBookStore` (temp file), and an
/// isolated `ServerPasswordStore` (per-test service string) so we can
/// observe the post-import state of both stores without contaminating
/// production data.
@MainActor
final class MumbleAppImportCoordinatorTests: XCTestCase {

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private var dbURL: URL!
    private var bookFileURL: URL!
    private var bookStore: ServerBookStore!
    private var passwords: ServerPasswordStore!
    private var keychainAccountsToCleanUp: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
        dbURL = tmp.appendingPathComponent("mumble-import-coord-\(UUID()).sqlite")
        bookFileURL = tmp.appendingPathComponent("mumble-import-coord-\(UUID()).json")
        bookStore = ServerBookStore(storageURL: bookFileURL)
        passwords = ServerPasswordStore(
            service: "com.nicholas-lonsinger.mumble-macos.tests.import-coord.\(UUID().uuidString)"
        )
    }

    override func tearDown() async throws {
        for id in keychainAccountsToCleanUp {
            try? passwords.deletePassword(forServer: id)
        }
        keychainAccountsToCleanUp.removeAll()
        if let dbURL { try? FileManager.default.removeItem(at: dbURL) }
        if let bookFileURL { try? FileManager.default.removeItem(at: bookFileURL) }
        bookStore = nil
        passwords = nil
        try await super.tearDown()
    }

    private func writeFixture(rows: [(name: String, host: String, port: Int, username: String, password: String)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE servers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT, hostname TEXT,
            port INTEGER DEFAULT 64738,
            username TEXT, password TEXT,
            url TEXT
        );
        """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db,
                "INSERT INTO servers (name, hostname, port, username, password) VALUES (?, ?, ?, ?, ?)",
                -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, row.name, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.host, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(row.port))
            sqlite3_bind_text(stmt, 4, row.username, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, row.password, -1, Self.SQLITE_TRANSIENT)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Happy path

    func test_importsAllRowsAndCreatesImportedGroup() throws {
        try writeFixture(rows: [
            ("Alpha", "alpha.example", 64738, "alice", "pw-a"),
            ("Beta", "beta.example", 12345, "bob", "")
        ])

        let coordinator = MumbleAppImportCoordinator(
            bookStore: bookStore,
            passwords: passwords,
            importer: MumbleAppImporter()
        )
        let summary = try coordinator.run(at: dbURL)
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.skippedDuplicates, 0)
        XCTAssertEqual(summary.passwordWriteFailures, 0)

        let importedGroup = try XCTUnwrap(bookStore.group(of: .imported))
        XCTAssertEqual(importedGroup.name, "Imported")
        let imported = bookStore.servers(in: importedGroup.id)
        XCTAssertEqual(Set(imported.map(\.label)), ["Alpha", "Beta"])

        // Track for keychain cleanup.
        keychainAccountsToCleanUp = imported.map(\.id)

        // Password should have been stored only for the entry whose
        // SQLite row had a non-empty password.
        let alpha = try XCTUnwrap(imported.first(where: { $0.label == "Alpha" }))
        let beta = try XCTUnwrap(imported.first(where: { $0.label == "Beta" }))
        XCTAssertEqual(alpha.passwordHandling, .useStoredPassword)
        XCTAssertEqual(try passwords.password(forServer: alpha.id), "pw-a")
        XCTAssertEqual(beta.passwordHandling, .noPasswordRequired)
        XCTAssertNil(try passwords.password(forServer: beta.id))
    }

    // MARK: - Idempotency

    func test_secondRunSkipsDuplicates() throws {
        try writeFixture(rows: [("Alpha", "alpha.example", 64738, "alice", "pw")])

        let coordinator = MumbleAppImportCoordinator(
            bookStore: bookStore,
            passwords: passwords,
            importer: MumbleAppImporter()
        )
        let first = try coordinator.run(at: dbURL)
        XCTAssertEqual(first.imported, 1)

        let second = try coordinator.run(at: dbURL)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skippedDuplicates, 1)

        // Track for cleanup.
        if let server = bookStore.servers.first {
            keychainAccountsToCleanUp = [server.id]
        }

        // Bookmark count should be 1, not 2.
        XCTAssertEqual(bookStore.servers.count, 1)
    }

    func test_dedupMatchesAcrossGroups() throws {
        // A pre-existing bookmark with same host/port/username should
        // count as a duplicate even when in a different group.
        let pre = SavedServer(
            label: "Manual Entry",
            host: "alpha.example",
            port: 64738,
            username: "alice",
            groupID: bookStore.group(of: .favorites)?.id
        )
        bookStore.addServer(pre)

        try writeFixture(rows: [("Alpha", "alpha.example", 64738, "alice", "")])
        let coordinator = MumbleAppImportCoordinator(
            bookStore: bookStore,
            passwords: passwords,
            importer: MumbleAppImporter()
        )
        let summary = try coordinator.run(at: dbURL)
        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.skippedDuplicates, 1)
    }

    func test_dedupIsCaseInsensitiveOnHost() throws {
        let pre = SavedServer(
            label: "Existing",
            host: "Alpha.Example",
            port: 64738,
            username: "alice",
            groupID: nil
        )
        bookStore.addServer(pre)

        try writeFixture(rows: [("Alpha", "alpha.example", 64738, "alice", "")])
        let summary = try MumbleAppImportCoordinator(
            bookStore: bookStore,
            passwords: passwords,
            importer: MumbleAppImporter()
        ).run(at: dbURL)
        XCTAssertEqual(summary.skippedDuplicates, 1)
    }
}
