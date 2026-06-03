import Foundation

/// Sibling ordering for every channel-tree presentation (main window
/// sidebar, whisper-target picker): ascending `position`, ties broken by
/// case-insensitive name. Extracted so the two trees can't drift.
enum ChannelTreeOrder {
    static func areInIncreasingOrder(_ lhs: ChannelNode, _ rhs: ChannelNode) -> Bool {
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// `node`'s children resolved against `channels`, sorted. Dangling
    /// child IDs (server-state diffs can briefly reference channels that
    /// haven't arrived or were removed) are silently skipped.
    static func sortedChildren(of node: ChannelNode,
                               in channels: [UInt32: ChannelNode]) -> [ChannelNode] {
        node.childChannelIDs
            .compactMap { channels[$0] }
            .sorted(by: areInIncreasingOrder)
    }
}
