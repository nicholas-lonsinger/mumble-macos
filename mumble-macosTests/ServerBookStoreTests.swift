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

    func test_removingPublicGroupAlsoClearsPublicSourceOnChildren() throws {
        // Regression: a stale `publicSource` flag on an orphaned server
        // would cause the next Refresh Public Servers to silently delete
        // it via `replaceServers(matching:)`. Removing the group is an
        // explicit "divorce these bookmarks from the public list," so
        // clear the flag on the way out.
        let store = ServerBookStore(storageURL: tempURL)
        let publicGroup = ServerGroup(name: "Public Servers", kind: .publicMumbleInfo)
        store.addGroup(publicGroup)
        let server = SavedServer(
            label: "Seeded", host: "seeded.example", port: 64738, username: "u",
            groupID: publicGroup.id, publicSource: .mumbleInfo
        )
        store.addServer(server)

        try store.removeGroup(id: publicGroup.id)

        let reloaded = try XCTUnwrap(store.server(id: server.id))
        XCTAssertNil(reloaded.groupID)
        XCTAssertNil(reloaded.publicSource,
                     "publicSource must be cleared when its seeded group is removed.")

        // And a follow-up Refresh-style replace must NOT delete the now-
        // independent bookmark — that's the whole point.
        store.replaceServers(matching: .mumbleInfo, with: [])
        XCTAssertNotNil(store.server(id: server.id))
    }

    func test_removingUserGroupKeepsPublicSourceUntouched() throws {
        // Belt-and-suspenders: a server that was somehow both in a user
        // group AND flagged with publicSource (e.g. user dragged it out
        // of Public into Work) must keep its flag intact when the user
        // group is removed — the flag's lifecycle is tied to the public
        // group, not to whichever folder the user has the entry in.
        let store = ServerBookStore(storageURL: tempURL)
        let userGroup = ServerGroup(name: "Work", kind: .user)
        store.addGroup(userGroup)
        let server = SavedServer(
            label: "X", host: "x", port: 1, username: "u",
            groupID: userGroup.id, publicSource: .mumbleInfo
        )
        store.addServer(server)

        try store.removeGroup(id: userGroup.id)

        let reloaded = try XCTUnwrap(store.server(id: server.id))
        XCTAssertEqual(reloaded.publicSource, .mumbleInfo)
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

    // MARK: - Move / reorder

    func test_moveServerToTopOfDestinationGroup() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let g1 = ServerGroup(name: "G1")
        let g2 = ServerGroup(name: "G2")
        store.addGroup(g1)
        store.addGroup(g2)

        let s1 = SavedServer(label: "Alpha", host: "a", port: 1, username: "u", groupID: g1.id, sortIndex: 1)
        let s2 = SavedServer(label: "Beta", host: "b", port: 1, username: "u", groupID: g1.id, sortIndex: 2)
        let s3 = SavedServer(label: "Gamma", host: "c", port: 1, username: "u", groupID: g2.id, sortIndex: 1)
        store.addServer(s1)
        store.addServer(s2)
        store.addServer(s3)

        // Move s2 to start of g2.
        try store.moveServer(s2.id, toGroup: g2.id, afterServerID: nil)

        let g2Sorted = store.servers(in: g2.id)
        XCTAssertEqual(g2Sorted.map(\.label), ["Beta", "Gamma"])
        // Source group should still contain s1 only.
        XCTAssertEqual(store.servers(in: g1.id).map(\.label), ["Alpha"])
        // Renumbered contiguously starting at 1.
        XCTAssertEqual(g2Sorted.map(\.sortIndex), [1, 2])
    }

    func test_moveServerAfterAnchorWithinSameGroup() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let g = try XCTUnwrap(store.group(of: .favorites)).id

        let a = SavedServer(label: "A", host: "a", port: 1, username: "u", groupID: g, sortIndex: 1)
        let b = SavedServer(label: "B", host: "b", port: 1, username: "u", groupID: g, sortIndex: 2)
        let c = SavedServer(label: "C", host: "c", port: 1, username: "u", groupID: g, sortIndex: 3)
        store.addServer(a)
        store.addServer(b)
        store.addServer(c)

        // Move A to land right after C → expected order B, C, A.
        try store.moveServer(a.id, toGroup: g, afterServerID: c.id)

        XCTAssertEqual(store.servers(in: g).map(\.label), ["B", "C", "A"])
    }

    func test_moveServerToTopLevel() throws {
        let store = ServerBookStore(storageURL: tempURL)
        let g = try XCTUnwrap(store.group(of: .favorites)).id

        let s = SavedServer(label: "S", host: "s", port: 1, username: "u", groupID: g, sortIndex: 1)
        store.addServer(s)

        try store.moveServer(s.id, toGroup: nil, afterServerID: nil)

        XCTAssertTrue(store.servers(in: g).isEmpty)
        XCTAssertEqual(store.servers(in: nil).map(\.label), ["S"])
    }

    func test_moveServerWithMissingAnchorFallsBackToStart() throws {
        // Anchor that isn't in the destination → drops at the front. Mirrors
        // what we want for cross-group drags where the source server's
        // sibling list is irrelevant in the destination.
        let store = ServerBookStore(storageURL: tempURL)
        let g1 = ServerGroup(name: "G1")
        let g2 = ServerGroup(name: "G2")
        store.addGroup(g1)
        store.addGroup(g2)

        let inG1 = SavedServer(label: "In G1", host: "a", port: 1, username: "u", groupID: g1.id, sortIndex: 1)
        let firstInG2 = SavedServer(label: "First", host: "b", port: 1, username: "u", groupID: g2.id, sortIndex: 1)
        store.addServer(inG1)
        store.addServer(firstInG2)

        // The anchor `firstInG2.id` lives in g2. We're moving inG1 to g1
        // (its current group) using firstInG2 as anchor — invalid for g1.
        try store.moveServer(inG1.id, toGroup: g1.id, afterServerID: firstInG2.id)

        XCTAssertEqual(store.servers(in: g1.id).map(\.label), ["In G1"])
    }

    func test_moveGroupReorders() throws {
        let store = ServerBookStore(storageURL: tempURL)
        // Wipe seed so we have a known starting set.
        let favorites = try XCTUnwrap(store.group(of: .favorites))
        let work = ServerGroup(name: "Work", sortIndex: 0, kind: .user)
        let friends = ServerGroup(name: "Friends", sortIndex: 0, kind: .user)
        store.addGroup(work)
        store.addGroup(friends)

        // Initial order: Favorites, Work, Friends (by sortIndex auto-bump).
        XCTAssertEqual(store.topLevelGroupsSorted.map(\.name), ["Favorites", "Work", "Friends"])

        // Move Friends to first position (after nil = at start).
        try store.moveGroup(friends.id, afterGroupID: nil)
        XCTAssertEqual(store.topLevelGroupsSorted.map(\.name), ["Friends", "Favorites", "Work"])

        // Move Favorites after Work.
        try store.moveGroup(favorites.id, afterGroupID: work.id)
        XCTAssertEqual(store.topLevelGroupsSorted.map(\.name), ["Friends", "Work", "Favorites"])
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
