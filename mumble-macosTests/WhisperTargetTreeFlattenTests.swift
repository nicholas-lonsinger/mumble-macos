import XCTest
@testable import mumble_macos

/// Tests for `WhisperTargetSheet.flattenTree`. The flatten-once-on-appear
/// design replaces a recursive `@ViewBuilder` that defeated `LazyVStack`
/// laziness on large channel trees; these tests pin the depth-first
/// ordering and per-level sort so future refactors don't regress it.
final class WhisperTargetTreeFlattenTests: XCTestCase {

    // MARK: - Helpers

    private func makeChannel(_ id: UInt32,
                             name: String,
                             parent: UInt32? = nil,
                             position: Int32 = 0,
                             children: [UInt32] = []) -> ChannelNode {
        ChannelNode(
            id: id,
            name: name,
            parentID: parent,
            description: nil,
            isTemporary: false,
            position: position,
            maxUsers: 0,
            childChannelIDs: children,
            userSessionIDs: []
        )
    }

    // MARK: - Empty / unknown root

    func test_flatten_emptyChannelsReturnsEmpty() {
        let result = WhisperTargetSheet.flattenTree(channels: [:], rootID: 1)
        XCTAssertTrue(result.isEmpty)
    }

    func test_flatten_nilRootReturnsEmpty() {
        let result = WhisperTargetSheet.flattenTree(channels: [:], rootID: nil)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Depth annotation

    func test_flatten_depthIncreasesPerNestingLevel() {
        let channels: [UInt32: ChannelNode] = [
            1: makeChannel(1, name: "Root", children: [2]),
            2: makeChannel(2, name: "Child", parent: 1, children: [3]),
            3: makeChannel(3, name: "Grandchild", parent: 2),
        ]
        let result = WhisperTargetSheet.flattenTree(channels: channels, rootID: 1)
        XCTAssertEqual(result.map(\.channelID), [1, 2, 3])
        XCTAssertEqual(result.map(\.depth), [0, 1, 2])
    }

    // MARK: - Sort order

    func test_flatten_sortsSiblingsByPositionThenName() {
        let channels: [UInt32: ChannelNode] = [
            1: makeChannel(1, name: "Root", children: [10, 20, 30, 40]),
            10: makeChannel(10, name: "Zeta", parent: 1, position: 1),
            20: makeChannel(20, name: "Alpha", parent: 1, position: 2),
            30: makeChannel(30, name: "Apple", parent: 1, position: 0),
            40: makeChannel(40, name: "Banana", parent: 1, position: 0),
        ]
        let result = WhisperTargetSheet.flattenTree(channels: channels, rootID: 1)
        // Position 0 first (Apple, Banana — alphabetical), then position 1
        // (Zeta), then position 2 (Alpha).
        XCTAssertEqual(result.map(\.channelID), [1, 30, 40, 10, 20])
    }

    // MARK: - Depth-first traversal

    func test_flatten_isDepthFirst() {
        // Each top-level child has its own subtree; the flatten should
        // yield each subtree contiguously rather than interleaving.
        let channels: [UInt32: ChannelNode] = [
            1: makeChannel(1, name: "Root", children: [10, 20]),
            10: makeChannel(10, name: "A", parent: 1, position: 0, children: [11]),
            11: makeChannel(11, name: "A1", parent: 10, position: 0),
            20: makeChannel(20, name: "B", parent: 1, position: 1, children: [21]),
            21: makeChannel(21, name: "B1", parent: 20, position: 0),
        ]
        let result = WhisperTargetSheet.flattenTree(channels: channels, rootID: 1)
        XCTAssertEqual(result.map(\.channelID), [1, 10, 11, 20, 21])
    }

    // MARK: - Missing children

    func test_flatten_skipsDanglingChildIDs() {
        // Server-state diffs can briefly leave a parent with a child id
        // that hasn't arrived yet (or has been removed). The flatten
        // should silently skip those rather than crash or insert blanks.
        let channels: [UInt32: ChannelNode] = [
            1: makeChannel(1, name: "Root", children: [2, 99]),
            2: makeChannel(2, name: "Real", parent: 1),
            // 99 is referenced as a child but missing from the dictionary.
        ]
        let result = WhisperTargetSheet.flattenTree(channels: channels, rootID: 1)
        XCTAssertEqual(result.map(\.channelID), [1, 2])
    }
}
