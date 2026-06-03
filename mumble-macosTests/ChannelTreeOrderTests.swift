import XCTest
@testable import mumble_macos

/// Pins the sibling ordering shared by the main-window channel tree and
/// the whisper-target picker: ascending position, case-insensitive name
/// tiebreak, dangling child IDs skipped.
final class ChannelTreeOrderTests: XCTestCase {

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

    func test_positionDominatesName() {
        let a = makeChannel(1, name: "Alpha", position: 5)
        let b = makeChannel(2, name: "Zeta", position: 1)
        XCTAssertTrue(ChannelTreeOrder.areInIncreasingOrder(b, a))
        XCTAssertFalse(ChannelTreeOrder.areInIncreasingOrder(a, b))
    }

    func test_nameTiebreakIsCaseInsensitive() {
        let lower = makeChannel(1, name: "apple", position: 0)
        let upper = makeChannel(2, name: "BANANA", position: 0)
        XCTAssertTrue(ChannelTreeOrder.areInIncreasingOrder(lower, upper))
        XCTAssertFalse(ChannelTreeOrder.areInIncreasingOrder(upper, lower))
    }

    func test_sortedChildrenResolvesAndSorts() {
        let root = makeChannel(1, name: "Root", children: [10, 20, 30])
        let channels: [UInt32: ChannelNode] = [
            1: root,
            10: makeChannel(10, name: "Zeta", parent: 1, position: 1),
            20: makeChannel(20, name: "alpha", parent: 1, position: 0),
            30: makeChannel(30, name: "Beta", parent: 1, position: 0),
        ]
        let sorted = ChannelTreeOrder.sortedChildren(of: root, in: channels)
        XCTAssertEqual(sorted.map(\.id), [20, 30, 10])
    }

    func test_sortedChildrenSkipsDanglingIDs() {
        let root = makeChannel(1, name: "Root", children: [2, 99])
        let channels: [UInt32: ChannelNode] = [
            1: root,
            2: makeChannel(2, name: "Real", parent: 1),
            // 99 referenced but missing — server-state diffs do this briefly.
        ]
        let sorted = ChannelTreeOrder.sortedChildren(of: root, in: channels)
        XCTAssertEqual(sorted.map(\.id), [2])
    }
}
