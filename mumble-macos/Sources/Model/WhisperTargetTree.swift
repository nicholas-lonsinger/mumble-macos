import Foundation

/// Depth-annotated flattening of the channel tree for the whisper-target
/// picker. The picker shows the tree always fully expanded, indented by
/// depth; flattening once keeps the row list a simple array. Per-level
/// order matches the main channel tree (`ChannelTreeOrder`). Pure so the
/// ordering is testable without any UI — see `WhisperTargetTreeFlattenTests`.
enum WhisperTargetTree {
    struct TreeRow: Identifiable, Equatable {
        let channelID: UInt32
        let name: String
        let depth: Int
        var id: UInt32 { channelID }
    }

    static func flattenTree(channels: [UInt32: ChannelNode],
                            rootID: UInt32?) -> [TreeRow] {
        guard let rootID, channels[rootID] != nil else { return [] }
        var out: [TreeRow] = []
        appendChannel(rootID, depth: 0, channels: channels, into: &out)
        return out
    }

    private static func appendChannel(_ channelID: UInt32,
                                      depth: Int,
                                      channels: [UInt32: ChannelNode],
                                      into out: inout [TreeRow]) {
        guard let channel = channels[channelID] else { return }
        out.append(TreeRow(channelID: channelID, name: channel.name, depth: depth))
        for child in ChannelTreeOrder.sortedChildren(of: channel, in: channels) {
            appendChannel(child.id, depth: depth + 1, channels: channels, into: &out)
        }
    }
}
