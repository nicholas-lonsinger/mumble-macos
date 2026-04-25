import XCTest
@testable import mumble_macos

/// Unit tests for `ServerBookStore`. Each test runs against a freshly-created
/// temp file URL so they don't share state with each other or with the user's
/// real `Servers.json`.
@MainActor
final class ServerBookStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Unique file per test — collisions would cause one test to read the
        // book another already populated.
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ServerBookStoreTests-\(UUID().uuidString).json",
            isDirectory: false
        )
    }

    override func tearDown() async throws {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        try await super.tearDown()
    }

    // MARK: - First-launch seeding

    func test_firstLaunchSeedsFavoritesGroupAndEmptyServers() {
        let store = ServerBookStore(storageURL: tempURL)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.kind, .favorites)
        XCTAssertEqual(store.groups.first?.name, "Favorites")
        XCTAssertTrue(store.servers.isEmpty)
    }

    func test_favoritesGroupCannotBeDeleted() {
        let store = ServerBookStore(storageURL: tempURL)
        let favorites = try! XCTUnwrap(store.group(of: .favorites))
        XCTAssertThrowsError(try store.removeGroup(id: favorites.id)) { error in
            guard case ServerBookStoreError.favoritesGroupNotDeletable = error else {
                return XCTFail("Expected favoritesGroupNotDeletable, got \(error)")
            }
        }
    }

    // MARK: - Server CRUD

    func test_addServerPersistsAndIsReadable() {
        let store = ServerBookStore(storageURL: tempURL)
        let id = UUID()
        store.addServer(SavedServer(
            id: id,
            label: "Test",
            host: "example.com",
            port: 64738,
            username: "alice"
        ))

        // Re-open from disk to confirm the JSON write-through path actually
        // persisted the entry.
        let reloaded = ServerBookStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.servers.count, 1)
        let s = try! XCTUnwrap(reloaded.server(id: id))
        XCTAssertEqual(s.label, "Test")
        XCTAssertEqual(s.host, "example.com")
        XCTAssertEqual(s.port, 64738)
        XCTAssertEqual(s.username, "alice")
    }

    func test_updateServerReplacesFields() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let server = SavedServer(label: "Old", host: "old.example", port: 1, username: "u")
        store.addServer(server)
        var updated = try XCTUnwrap(store.server(id: server.id))
        updated.label = "New"
        updated.host = "new.example"
        try store.updateServer(updated)

        let reloaded = ServerBookStore(storageURL: tempURL)
        let read = try XCTUnwrap(reloaded.server(id: server.id))
        XCTAssertEqual(read.label, "New")
        XCTAssertEqual(read.host, "new.example")
    }

    func test_updateUnknownServerThrows() {
        let store = ServerBookStore(storageURL: tempURL)
        let stranger = SavedServer(label: "X", host: "x", port: 1, username: "u")
        XCTAssertThrowsError(try store.updateServer(stranger))
    }

    func test_removeServerDeletesIt() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let server = SavedServer(label: "Doomed", host: "x", port: 1, username: "u")
        store.addServer(server)
        try store.removeServer(id: server.id)
        XCTAssertNil(store.server(id: server.id))
    }

    // MARK: - Sort order

    func test_serversInGroupAreSortedByIndexThenLabel() {
        let store = ServerBookStore(storageURL: tempURL)
        let g = try! XCTUnwrap(store.group(of: .favorites)).id

        // Identical sortIndex → fall back to label order. Two with the same
        // index, one above and one below.
        store.addServer(SavedServer(label: "Beta", host: "b", port: 1, username: "u",
                                    groupID: g, sortIndex: 5))
        store.addServer(SavedServer(label: "Alpha", host: "a", port: 1, username: "u",
                                    groupID: g, sortIndex: 5))
        store.addServer(SavedServer(label: "Zeta", host: "z", port: 1, username: "u",
                                    groupID: g, sortIndex: 1))

        let sorted = store.servers(in: g).map(\.label)
        XCTAssertEqual(sorted, ["Zeta", "Alpha", "Beta"])
    }

    func test_addServerWithoutSortIndexAppendsAtEnd() {
        let store = ServerBookStore(storageURL: tempURL)
        let g = try! XCTUnwrap(store.group(of: .favorites)).id

        store.addServer(SavedServer(label: "First", host: "a", port: 1, username: "u",
                                    groupID: g, sortIndex: 1))
        store.addServer(SavedServer(label: "Second", host: "b", port: 1, username: "u",
                                    groupID: g, sortIndex: 0)) // 0 means "auto"
        // Auto-assigned sortIndex should be > 1, so Second comes after First.
        XCTAssertEqual(store.servers(in: g).map(\.label), ["First", "Second"])
    }

    // MARK: - Group CRUD

    func test_addGroupAndRemove() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let group = ServerGroup(name: "Work")
        store.addGroup(group)
        XCTAssertNotNil(store.group(id: group.id))

        try store.removeGroup(id: group.id)
        XCTAssertNil(store.group(id: group.id))
    }

    func test_removingGroupUnlinksItsServers() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let group = ServerGroup(name: "Temp")
        store.addGroup(group)
        let server = SavedServer(label: "S", host: "h", port: 1, username: "u",
                                 groupID: group.id)
        store.addServer(server)

        try store.removeGroup(id: group.id)

        let reloaded = ServerBookStore(storageURL: tempURL)
        let s = try XCTUnwrap(reloaded.server(id: server.id))
        XCTAssertNil(s.groupID, "Servers should land in the top level when their group is deleted, not be silently dropped.")
    }

    // MARK: - Public-source replacement

    func test_replaceServersMatchingSourceLeavesOthersAlone() {
        let store = ServerBookStore(storageURL: tempURL)
        let untouched = SavedServer(label: "Mine", host: "mine.example", port: 1, username: "u",
                                    publicSource: nil)
        let oldPublic = SavedServer(label: "OldPublic", host: "old.example", port: 1, username: "u",
                                    publicSource: .mumbleInfo)
        store.addServer(untouched)
        store.addServer(oldPublic)

        let replacement = SavedServer(label: "NewPublic", host: "new.example", port: 1, username: "u",
                                      publicSource: .mumbleInfo)
        store.replaceServers(matching: .mumbleInfo, with: [replacement])

        XCTAssertNotNil(store.server(id: untouched.id), "User-owned servers must survive a public-source refresh.")
        XCTAssertNil(store.server(id: oldPublic.id), "Old seeded servers must be replaced.")
        XCTAssertNotNil(store.server(id: replacement.id))
    }

    // MARK: - Recovery

    func test_corruptFileIsQuarantinedAndStoreReseeds() throws {
        // Hand-write garbage at the storage URL so the decoder fails. The
        // store should rename it (quarantine sidecar) and start fresh
        // rather than crash or silently lose data.
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: tempURL)

        let store = ServerBookStore(storageURL: tempURL)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.kind, .favorites)

        // The corrupt file should have been moved aside, not deleted.
        let dir = tempURL.deletingLastPathComponent().path
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        let prefix = tempURL.deletingPathExtension().lastPathComponent + ".corrupt-"
        XCTAssertTrue(siblings.contains(where: { $0.hasPrefix(prefix) }),
                      "Corrupt file should be renamed with a `.corrupt-<timestamp>.json` sidecar.")

        // Cleanup quarantine sidecar so it doesn't accumulate across runs.
        for name in siblings where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }
}
