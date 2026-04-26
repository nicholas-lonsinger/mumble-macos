import XCTest
@testable import mumble_macos

/// Round-trip tests for `ServerPasswordStore`. Each test uses a unique
/// keychain service string so it cannot collide with the production store
/// or with another test, and `tearDown` clears every entry it wrote.
///
/// We rely on the same data-protection-keychain plumbing as `IdentityStore`
/// (already covered structurally by `PKCS12EncoderTests` against a real
/// `SecPKCS12Import`); this suite focuses on the password‐specific surface.
final class ServerPasswordStoreTests: XCTestCase {

    private var store: ServerPasswordStore!
    private var writtenIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        // Per-test service string keeps these isolated from production
        // keys and from sibling tests running in the same suite.
        store = ServerPasswordStore(
            service: "com.nicholas-lonsinger.mumble-macos.tests.\(UUID().uuidString)"
        )
        writtenIDs.removeAll()
    }

    override func tearDown() {
        for id in writtenIDs {
            try? store.deletePassword(forServer: id)
        }
        writtenIDs.removeAll()
        store = nil
        super.tearDown()
    }

    private func record(_ id: UUID) -> UUID { writtenIDs.append(id); return id }

    // MARK: - Round-trip

    func test_setAndReadPassword() throws {
        let id = record(UUID())
        try store.setPassword("hunter2", forServer: id)
        XCTAssertEqual(try store.password(forServer: id), "hunter2")
    }

    func test_readMissingReturnsNil() throws {
        XCTAssertNil(try store.password(forServer: UUID()))
    }

    func test_setReplacesExisting() throws {
        let id = record(UUID())
        try store.setPassword("first", forServer: id)
        try store.setPassword("second", forServer: id)
        XCTAssertEqual(try store.password(forServer: id), "second")
    }

    func test_deletePassword() throws {
        let id = record(UUID())
        try store.setPassword("temp", forServer: id)
        try store.deletePassword(forServer: id)
        XCTAssertNil(try store.password(forServer: id))
    }

    func test_deleteMissingDoesNotThrow() throws {
        XCTAssertNoThrow(try store.deletePassword(forServer: UUID()))
    }

    // MARK: - Boundary

    func test_emptyPasswordRoundTrips() throws {
        // Mumble allows empty passwords (guest connect). Make sure the
        // store doesn't treat empty as "no entry" — that would silently
        // promote a remembered-but-blank password to "missing".
        let id = record(UUID())
        try store.setPassword("", forServer: id)
        XCTAssertEqual(try store.password(forServer: id), "")
    }

    func test_unicodePasswordRoundTrips() throws {
        let id = record(UUID())
        let pw = "пароль🔐 ŞifrE"
        try store.setPassword(pw, forServer: id)
        XCTAssertEqual(try store.password(forServer: id), pw)
    }

    func test_isolatedAcrossServerIDs() throws {
        let a = record(UUID())
        let b = record(UUID())
        try store.setPassword("aaa", forServer: a)
        try store.setPassword("bbb", forServer: b)
        XCTAssertEqual(try store.password(forServer: a), "aaa")
        XCTAssertEqual(try store.password(forServer: b), "bbb")
    }
}
