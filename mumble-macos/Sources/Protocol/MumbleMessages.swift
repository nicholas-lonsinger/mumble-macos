import Foundation

// Struct representations of the Mumble control messages we care about.
// Field numbers match Mumble.proto; only fields the MVP uses are modelled —
// additional fields can be added here as features expand.

protocol MumbleOutgoingMessage: Sendable {
    static var messageType: MumbleMessageType { get }
    func encodePayload() -> Data
}

protocol MumbleIncomingMessage: Sendable {
    init(reader: inout ProtobufReader) throws
}

extension MumbleOutgoingMessage {
    func encodeFrame() -> Data {
        MumbleFraming.encode(type: Self.messageType, payload: encodePayload())
    }
}

// MARK: - Version

struct VersionMessage: MumbleOutgoingMessage, MumbleIncomingMessage {
    static let messageType: MumbleMessageType = .version

    var versionV1: UInt32?
    var versionV2: UInt64?
    var release: String?
    var os: String?
    var osVersion: String?

    init(versionV1: UInt32? = nil,
         versionV2: UInt64? = nil,
         release: String? = nil,
         os: String? = nil,
         osVersion: String? = nil) {
        self.versionV1 = versionV1
        self.versionV2 = versionV2
        self.release = release
        self.os = os
        self.osVersion = osVersion
    }

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): versionV1 = try reader.readUInt32()
            case (2, .lengthDelimited): release = try reader.readString()
            case (3, .lengthDelimited): os = try reader.readString()
            case (4, .lengthDelimited): osVersion = try reader.readString()
            case (5, .varint): versionV2 = try reader.readVarint()
            default: try reader.skipField(wire)
            }
        }
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        if let versionV1 { writer.writeField(1, uint32: versionV1) }
        if let release { writer.writeField(2, string: release) }
        if let os { writer.writeField(3, string: os) }
        if let osVersion { writer.writeField(4, string: osVersion) }
        if let versionV2 { writer.writeField(5, uint64: versionV2) }
        return writer.data
    }
}

// MARK: - Authenticate

struct AuthenticateMessage: MumbleOutgoingMessage {
    static let messageType: MumbleMessageType = .authenticate

    var username: String
    var password: String
    var tokens: [String]
    var celtVersions: [Int32]
    var opus: Bool
    var clientType: Int32

    init(username: String,
         password: String = "",
         tokens: [String] = [],
         celtVersions: [Int32] = [],
         opus: Bool = true,
         clientType: Int32 = 0) {
        self.username = username
        self.password = password
        self.tokens = tokens
        self.celtVersions = celtVersions
        self.opus = opus
        self.clientType = clientType
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        writer.writeField(1, string: username)
        writer.writeField(2, string: password)
        for token in tokens {
            writer.writeField(3, string: token)
        }
        for celt in celtVersions {
            writer.writeField(4, int32: celt)
        }
        writer.writeField(5, bool: opus)
        writer.writeField(6, int32: clientType)
        return writer.data
    }
}

// MARK: - Ping

struct PingMessage: MumbleOutgoingMessage, MumbleIncomingMessage {
    static let messageType: MumbleMessageType = .ping

    var timestamp: UInt64?
    var good: UInt32?
    var late: UInt32?
    var lost: UInt32?
    var resync: UInt32?
    var udpPackets: UInt32?
    var tcpPackets: UInt32?
    var udpPingAvg: Float?
    var udpPingVar: Float?
    var tcpPingAvg: Float?
    var tcpPingVar: Float?

    init(timestamp: UInt64? = nil) {
        self.timestamp = timestamp
    }

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): timestamp = try reader.readVarint()
            case (2, .varint): good = try reader.readUInt32()
            case (3, .varint): late = try reader.readUInt32()
            case (4, .varint): lost = try reader.readUInt32()
            case (5, .varint): resync = try reader.readUInt32()
            case (6, .varint): udpPackets = try reader.readUInt32()
            case (7, .varint): tcpPackets = try reader.readUInt32()
            case (8, .fixed32): udpPingAvg = try reader.readFloat()
            case (9, .fixed32): udpPingVar = try reader.readFloat()
            case (10, .fixed32): tcpPingAvg = try reader.readFloat()
            case (11, .fixed32): tcpPingVar = try reader.readFloat()
            default: try reader.skipField(wire)
            }
        }
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        if let timestamp { writer.writeField(1, uint64: timestamp) }
        return writer.data
    }
}

// MARK: - Reject

struct RejectMessage: MumbleIncomingMessage {
    enum RejectType: Int32, Sendable {
        case unknown = 0
        case wrongVersion = 1
        case invalidUsername = 2
        case wrongUserPassword = 3
        case wrongServerPassword = 4
        case usernameInUse = 5
        case serverFull = 6
        case noCertificate = 7
        case authenticatorFail = 8
        case noNewConnections = 9
    }

    var type: RejectType?
    var reason: String?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint):
                type = RejectType(rawValue: try reader.readInt32())
            case (2, .lengthDelimited):
                reason = try reader.readString()
            default:
                try reader.skipField(wire)
            }
        }
    }

    var humanDescription: String {
        if let reason, !reason.isEmpty { return reason }
        switch type {
        case .wrongVersion: return "Incompatible protocol version."
        case .invalidUsername: return "The username is not allowed."
        case .wrongUserPassword: return "User password is wrong."
        case .wrongServerPassword: return "Server password is wrong."
        case .usernameInUse: return "Username is already in use."
        case .serverFull: return "The server is full."
        case .noCertificate: return "A client certificate is required."
        case .authenticatorFail: return "The server authenticator rejected the request."
        case .noNewConnections: return "The server is not accepting new connections."
        case .unknown, nil: return "Connection rejected."
        }
    }
}

// MARK: - ServerSync

struct ServerSyncMessage: MumbleIncomingMessage {
    var session: UInt32?
    var maxBandwidth: UInt32?
    var welcomeText: String?
    var permissions: UInt64?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): session = try reader.readUInt32()
            case (2, .varint): maxBandwidth = try reader.readUInt32()
            case (3, .lengthDelimited): welcomeText = try reader.readString()
            case (4, .varint): permissions = try reader.readVarint()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - ChannelState

struct ChannelStateMessage: MumbleIncomingMessage {
    var channelID: UInt32?
    var parent: UInt32?
    var name: String?
    var description: String?
    var temporary: Bool?
    var position: Int32?
    var maxUsers: UInt32?
    var descriptionHash: Data?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): channelID = try reader.readUInt32()
            case (2, .varint): parent = try reader.readUInt32()
            case (3, .lengthDelimited): name = try reader.readString()
            case (5, .lengthDelimited): description = try reader.readString()
            case (8, .varint): temporary = try reader.readBool()
            case (9, .varint): position = try reader.readInt32()
            case (10, .lengthDelimited): descriptionHash = try reader.readBytes()
            case (11, .varint): maxUsers = try reader.readUInt32()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - ChannelRemove

struct ChannelRemoveMessage: MumbleIncomingMessage {
    var channelID: UInt32

    init(reader: inout ProtobufReader) throws {
        var channelID: UInt32 = 0
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): channelID = try reader.readUInt32()
            default: try reader.skipField(wire)
            }
        }
        self.channelID = channelID
    }
}

// MARK: - UserState

struct UserStateMessage: MumbleIncomingMessage {
    var session: UInt32?
    var actor: UInt32?
    var name: String?
    var userID: UInt32?
    var channelID: UInt32?
    var mute: Bool?
    var deaf: Bool?
    var suppress: Bool?
    var selfMute: Bool?
    var selfDeaf: Bool?
    var comment: String?
    var hash: String?
    var prioritySpeaker: Bool?
    var recording: Bool?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): session = try reader.readUInt32()
            case (2, .varint): actor = try reader.readUInt32()
            case (3, .lengthDelimited): name = try reader.readString()
            case (4, .varint): userID = try reader.readUInt32()
            case (5, .varint): channelID = try reader.readUInt32()
            case (6, .varint): mute = try reader.readBool()
            case (7, .varint): deaf = try reader.readBool()
            case (8, .varint): suppress = try reader.readBool()
            case (9, .varint): selfMute = try reader.readBool()
            case (10, .varint): selfDeaf = try reader.readBool()
            case (14, .lengthDelimited): comment = try reader.readString()
            case (15, .lengthDelimited): hash = try reader.readString()
            case (18, .varint): prioritySpeaker = try reader.readBool()
            case (19, .varint): recording = try reader.readBool()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - UserRemove

struct UserRemoveMessage: MumbleIncomingMessage {
    var session: UInt32
    var actor: UInt32?
    var reason: String?
    var ban: Bool?

    init(reader: inout ProtobufReader) throws {
        var session: UInt32 = 0
        var actor: UInt32?
        var reason: String?
        var ban: Bool?
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): session = try reader.readUInt32()
            case (2, .varint): actor = try reader.readUInt32()
            case (3, .lengthDelimited): reason = try reader.readString()
            case (4, .varint): ban = try reader.readBool()
            default: try reader.skipField(wire)
            }
        }
        self.session = session
        self.actor = actor
        self.reason = reason
        self.ban = ban
    }
}

// MARK: - TextMessage

struct TextMessageMessage: MumbleIncomingMessage, MumbleOutgoingMessage {
    static let messageType: MumbleMessageType = .textMessage

    var actor: UInt32?
    var sessions: [UInt32]
    var channelIDs: [UInt32]
    var treeIDs: [UInt32]
    var message: String

    init(actor: UInt32? = nil,
         sessions: [UInt32] = [],
         channelIDs: [UInt32] = [],
         treeIDs: [UInt32] = [],
         message: String) {
        self.actor = actor
        self.sessions = sessions
        self.channelIDs = channelIDs
        self.treeIDs = treeIDs
        self.message = message
    }

    init(reader: inout ProtobufReader) throws {
        var actor: UInt32?
        var sessions: [UInt32] = []
        var channelIDs: [UInt32] = []
        var treeIDs: [UInt32] = []
        var message = ""
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): actor = try reader.readUInt32()
            case (2, .varint): sessions.append(try reader.readUInt32())
            case (3, .varint): channelIDs.append(try reader.readUInt32())
            case (4, .varint): treeIDs.append(try reader.readUInt32())
            case (5, .lengthDelimited): message = try reader.readString()
            default: try reader.skipField(wire)
            }
        }
        self.actor = actor
        self.sessions = sessions
        self.channelIDs = channelIDs
        self.treeIDs = treeIDs
        self.message = message
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        if let actor { writer.writeField(1, uint32: actor) }
        for session in sessions { writer.writeField(2, uint32: session) }
        for channelID in channelIDs { writer.writeField(3, uint32: channelID) }
        for tree in treeIDs { writer.writeField(4, uint32: tree) }
        writer.writeField(5, string: message)
        return writer.data
    }
}

// MARK: - CodecVersion

struct CodecVersionMessage: MumbleIncomingMessage {
    var alpha: Int32 = 0
    var beta: Int32 = 0
    var preferAlpha: Bool = true
    var opus: Bool = false

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): alpha = try reader.readInt32()
            case (2, .varint): beta = try reader.readInt32()
            case (3, .varint): preferAlpha = try reader.readBool()
            case (4, .varint): opus = try reader.readBool()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - CryptSetup

struct CryptSetupMessage: MumbleIncomingMessage {
    var key: Data?
    var clientNonce: Data?
    var serverNonce: Data?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .lengthDelimited): key = try reader.readBytes()
            case (2, .lengthDelimited): clientNonce = try reader.readBytes()
            case (3, .lengthDelimited): serverNonce = try reader.readBytes()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - ServerConfig

struct ServerConfigMessage: MumbleIncomingMessage {
    var maxBandwidth: UInt32?
    var welcomeText: String?
    var allowHtml: Bool?
    var messageLength: UInt32?
    var imageMessageLength: UInt32?
    var maxUsers: UInt32?
    var recordingAllowed: Bool?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): maxBandwidth = try reader.readUInt32()
            case (2, .lengthDelimited): welcomeText = try reader.readString()
            case (3, .varint): allowHtml = try reader.readBool()
            case (4, .varint): messageLength = try reader.readUInt32()
            case (5, .varint): imageMessageLength = try reader.readUInt32()
            case (6, .varint): maxUsers = try reader.readUInt32()
            case (7, .varint): recordingAllowed = try reader.readBool()
            default: try reader.skipField(wire)
            }
        }
    }
}

// MARK: - PermissionDenied

struct PermissionDeniedMessage: MumbleIncomingMessage {
    var reason: String?

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (4, .lengthDelimited): reason = try reader.readString()
            default: try reader.skipField(wire)
            }
        }
    }
}
