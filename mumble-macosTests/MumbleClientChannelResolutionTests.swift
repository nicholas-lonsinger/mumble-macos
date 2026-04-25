import XCTest
@testable import mumble_macos

/// Exercises `MumbleClient.resolveChannel(path:in:rootID:)`. The matching
/// rules mirror the reference client's `MainWindow::findDesiredChannel`
/// (mumble/src/mumble/MainWindow.cpp:1387) so that a `mumble://host/A/B`
/// link routes to the same channel in both clients.
final class MumbleClientChannelResolutionTests: XCTestCase {

    // MARK: - Tree builder

    /// Build a synthetic channel map. Pass `(id, parentID?, name)` tuples in
    /// any order — the helper backfills `childChannelIDs`.
    private func buildTree(_ rows: [(UInt32, UInt32?, String)]) -> [UInt32: ChannelNode] {
        var nodes: [UInt32: ChannelNode] = [:]
        for (id, parentID, name) in rows {
            nodes[id] = ChannelNode(
                id: id,
                name: name,
                parentID: parentID,
                description: nil,
                isTemporary: false,
                position: 0,
                maxUsers: 0,
                childChannelIDs: [],
                userSessionIDs: []
            )
        }
        for (id, parentID, _) in rows {
            guard let parentID, var parent = nodes[parentID] else { continue }
            parent.childChannelIDs.append(id)
            nodes[parentID] = parent
        }
        return nodes
    }

    // MARK: - Basic shapes

    func test_singleSegment_matches() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Lobby"),
            (2, 0, "Other"),
        ])
        let id = MumbleClient.resolveChannel(path: ["Lobby"], in: tree, rootID: 0)
        XCTAssertEqual(id, 1)
    }

    func test_nestedPath_matches() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Music"),
            (2, 1, "Lounge"),
            (3, 1, "Studio"),
        ])
        let id = MumbleClient.resolveChannel(path: ["Music", "Lounge"], in: tree, rootID: 0)
        XCTAssertEqual(id, 2)
    }

    func test_matchesCaseInsensitively() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Lobby"),
        ])
        let id = MumbleClient.resolveChannel(path: ["LOBBY"], in: tree, rootID: 0)
        XCTAssertEqual(id, 1)
    }

    func test_emptyPath_returnsNil() {
        let tree = buildTree([(0, nil, "Root")])
        XCTAssertNil(MumbleClient.resolveChannel(path: [], in: tree, rootID: 0))
    }

    func test_noMatch_returnsNil() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Lobby"),
        ])
        XCTAssertNil(MumbleClient.resolveChannel(path: ["DoesNotExist"], in: tree, rootID: 0))
    }

    func test_emptySegments_areSkipped() {
        // The reference splits a path on '/' which can produce empty tokens
        // (leading/trailing/double slashes). Those must not derail the walk.
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Lobby"),
        ])
        let id = MumbleClient.resolveChannel(path: ["", "Lobby", ""], in: tree, rootID: 0)
        XCTAssertEqual(id, 1)
    }

    // MARK: - Composite name with embedded '/'

    /// The reference algorithm's signature trick: when a segment doesn't
    /// match, accumulate it and try `prev/next`. This lets channel names
    /// that themselves contain a slash resolve cleanly from
    /// `mumble://host/Foo/Bar` even though the URL parser saw two segments.
    func test_compositeNameContainingSlash_resolves() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Music/Hall"),
        ])
        let id = MumbleClient.resolveChannel(path: ["Music", "Hall"], in: tree, rootID: 0)
        XCTAssertEqual(id, 1)
    }

    func test_compositeNameThenChild_resolves() {
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Music/Hall"),
            (2, 1, "Stage"),
        ])
        let id = MumbleClient.resolveChannel(path: ["Music", "Hall", "Stage"], in: tree, rootID: 0)
        XCTAssertEqual(id, 2)
    }

    // MARK: - Edge cases

    func test_unknownRoot_returnsNil() {
        let tree = buildTree([(0, nil, "Root")])
        XCTAssertNil(MumbleClient.resolveChannel(path: ["Anything"], in: tree, rootID: 99))
    }

    func test_partialMatch_returnsDeepestMatchedAncestor() {
        // Reference behaviour: once we've descended one level, the fact that
        // a later segment doesn't resolve doesn't unwind us — the algorithm
        // just stops descending and we stay at the last matched channel.
        // (The path is "best effort", not "all-or-nothing".)
        let tree = buildTree([
            (0, nil, "Root"),
            (1, 0, "Music"),
        ])
        let id = MumbleClient.resolveChannel(path: ["Music", "DoesNotExist"], in: tree, rootID: 0)
        XCTAssertEqual(id, 1)
    }
}
