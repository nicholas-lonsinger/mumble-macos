import Foundation

/// `VoiceTarget` control message — registers a "talk to channel/users" slot
/// (id 1..30) on the server. Per-packet `target` field on outgoing audio
/// matches the slot id; 0 = normal talk, 1..30 = whisper, 31 = server loopback.
///
/// See `mumble/src/Mumble.proto:464-482` for the upstream definition.
struct VoiceTargetMessage: MumbleOutgoingMessage {
    static let messageType: MumbleMessageType = .voiceTarget

    struct Target: Sendable, Equatable {
        var sessions: [UInt32]
        var channelID: UInt32?
        var group: String?
        var includeLinks: Bool?
        var includeChildren: Bool?

        init(sessions: [UInt32] = [],
             channelID: UInt32? = nil,
             group: String? = nil,
             includeLinks: Bool? = nil,
             includeChildren: Bool? = nil) {
            self.sessions = sessions
            self.channelID = channelID
            self.group = group
            self.includeLinks = includeLinks
            self.includeChildren = includeChildren
        }
    }

    var id: UInt32
    var targets: [Target]

    init(id: UInt32, targets: [Target] = []) {
        self.id = id
        self.targets = targets
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        writer.writeField(1, uint32: id)
        for target in targets {
            var inner = ProtobufWriter()
            for session in target.sessions {
                inner.writeField(1, uint32: session)
            }
            if let channelID = target.channelID { inner.writeField(2, uint32: channelID) }
            if let group = target.group, !group.isEmpty { inner.writeField(3, string: group) }
            if let links = target.includeLinks       { inner.writeField(4, bool: links) }
            if let children = target.includeChildren { inner.writeField(5, bool: children) }
            writer.writeField(2, message: inner.data)
        }
        return writer.data
    }
}
