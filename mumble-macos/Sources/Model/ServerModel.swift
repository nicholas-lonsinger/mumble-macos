import Foundation

struct ChannelNode: Identifiable, Sendable, Equatable {
    let id: UInt32
    var name: String
    var parentID: UInt32?
    var description: String?
    var isTemporary: Bool
    var position: Int32
    var maxUsers: UInt32
    var childChannelIDs: [UInt32]
    var userSessionIDs: [UInt32]
}

struct UserNode: Identifiable, Sendable, Equatable {
    let id: UInt32
    var name: String
    var channelID: UInt32
    var userID: UInt32?
    var isMuted: Bool
    var isDeafened: Bool
    var isSelfMuted: Bool
    var isSelfDeafened: Bool
    var isSuppressed: Bool
    var isPrioritySpeaker: Bool
    var isRecording: Bool
    var comment: String?
    var hash: String?
}
