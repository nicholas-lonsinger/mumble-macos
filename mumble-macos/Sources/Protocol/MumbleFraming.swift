import Foundation

enum MumbleMessageType: UInt16, CaseIterable, Sendable {
    case version = 0
    case udpTunnel = 1
    case authenticate = 2
    case ping = 3
    case reject = 4
    case serverSync = 5
    case channelRemove = 6
    case channelState = 7
    case userRemove = 8
    case userState = 9
    case banList = 10
    case textMessage = 11
    case permissionDenied = 12
    case acl = 13
    case queryUsers = 14
    case cryptSetup = 15
    case contextActionModify = 16
    case contextAction = 17
    case userList = 18
    case voiceTarget = 19
    case permissionQuery = 20
    case codecVersion = 21
    case userStats = 22
    case requestBlob = 23
    case serverConfig = 24
    case suggestConfig = 25
    case pluginDataTransmission = 26
}

enum MumbleFraming {
    static let headerSize = 6

    struct Header: Sendable, Equatable {
        let type: MumbleMessageType
        let payloadLength: UInt32
    }

    static func encode(type: MumbleMessageType, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        let raw = type.rawValue
        out.append(UInt8((raw >> 8) & 0xFF))
        out.append(UInt8(raw & 0xFF))
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(payload)
        return out
    }

    static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let start = data.startIndex
        let rawType = (UInt16(data[start]) << 8) | UInt16(data[start + 1])
        guard let type = MumbleMessageType(rawValue: rawType) else { return nil }
        let length = (UInt32(data[start + 2]) << 24)
            | (UInt32(data[start + 3]) << 16)
            | (UInt32(data[start + 4]) << 8)
            | UInt32(data[start + 5])
        return Header(type: type, payloadLength: length)
    }
}

enum MumbleVersion {
    static func fullVersionV2(major: UInt16, minor: UInt16, patch: UInt16) -> UInt64 {
        (UInt64(major) << 48) | (UInt64(minor) << 32) | (UInt64(patch) << 16)
    }

    static func legacyVersionV1(major: UInt16, minor: UInt8, patch: UInt8) -> UInt32 {
        (UInt32(major) << 16) | (UInt32(minor) << 8) | UInt32(patch)
    }

    static func components(fromV2 version: UInt64) -> (major: UInt16, minor: UInt16, patch: UInt16) {
        let major = UInt16(truncatingIfNeeded: (version >> 48) & 0xFFFF)
        let minor = UInt16(truncatingIfNeeded: (version >> 32) & 0xFFFF)
        let patch = UInt16(truncatingIfNeeded: (version >> 16) & 0xFFFF)
        return (major, minor, patch)
    }
}
