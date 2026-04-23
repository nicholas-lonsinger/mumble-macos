import Foundation

/// Messages carried over the UDP path. When UDP isn't available, the same
/// payload is sent inside a TCP UDPTunnel frame. Each UDP packet is one
/// byte of message type followed by the protobuf body.
enum MumbleUDPMessageType: UInt8, Sendable {
    case audio = 0
    case ping = 1
}

/// Mirrors `MumbleUDP.Audio` from the upstream Mumble protocol (v1.5 protobuf
/// format). Only the fields we actually read/write are represented.
struct UDPAudioMessage: Sendable, Equatable {
    var target: UInt32?
    var context: UInt32?
    var senderSession: UInt32?
    var frameNumber: UInt64?
    var opusData: Data = Data()
    var positionalData: [Float] = []
    var volumeAdjustment: Float?
    var isTerminator: Bool = false

    init(target: UInt32? = nil,
         frameNumber: UInt64? = nil,
         opusData: Data = Data(),
         isTerminator: Bool = false) {
        self.target = target
        self.frameNumber = frameNumber
        self.opusData = opusData
        self.isTerminator = isTerminator
    }

    init(reader: inout ProtobufReader) throws {
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, .varint): target = try reader.readUInt32()
            case (2, .varint): context = try reader.readUInt32()
            case (3, .varint): senderSession = try reader.readUInt32()
            case (4, .varint): frameNumber = try reader.readVarint()
            case (5, .lengthDelimited): opusData = try reader.readBytes()
            case (6, .lengthDelimited):
                // Packed repeated float
                let bytes = try reader.readBytes()
                var floats: [Float] = []
                floats.reserveCapacity(bytes.count / 4)
                bytes.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: UInt32.self)
                    for i in 0..<(bytes.count / 4) {
                        let bits = UInt32(littleEndian: base[i])
                        floats.append(Float(bitPattern: bits))
                    }
                }
                positionalData = floats
            case (6, .fixed32):
                // Non-packed float (spec allows either form)
                positionalData.append(try reader.readFloat())
            case (7, .fixed32): volumeAdjustment = try reader.readFloat()
            case (16, .varint): isTerminator = try reader.readBool()
            default: try reader.skipField(wire)
            }
        }
    }

    func encodePayload() -> Data {
        var writer = ProtobufWriter()
        if let target { writer.writeField(1, uint32: target) }
        if let context { writer.writeField(2, uint32: context) }
        if let senderSession { writer.writeField(3, uint32: senderSession) }
        if let frameNumber { writer.writeField(4, uint64: frameNumber) }
        if !opusData.isEmpty { writer.writeField(5, data: opusData) }
        if !positionalData.isEmpty {
            // Packed repeated float: one length-delimited field containing all values.
            var inner = Data(capacity: positionalData.count * 4)
            for value in positionalData {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { inner.append(contentsOf: $0) }
            }
            writer.writeField(6, data: inner)
        }
        if let volumeAdjustment { writer.writeField(7, float: volumeAdjustment) }
        if isTerminator { writer.writeField(16, bool: true) }
        return writer.data
    }

    /// Wraps the encoded protobuf in the one-byte-type prefix used on the UDP
    /// wire and inside TCP UDPTunnel payloads.
    func tunneledPacket() -> Data {
        var out = Data(capacity: 1 + opusData.count + 16)
        out.append(MumbleUDPMessageType.audio.rawValue)
        out.append(encodePayload())
        return out
    }

    /// Parses a TCP UDPTunnel / UDP packet body. Returns `nil` if the first
    /// byte isn't `MumbleUDPMessageType.audio`.
    static func decode(tunneled data: Data) throws -> UDPAudioMessage? {
        guard let first = data.first else { return nil }
        guard first == MumbleUDPMessageType.audio.rawValue else { return nil }
        var reader = ProtobufReader(data.dropFirst())
        return try UDPAudioMessage(reader: &reader)
    }
}
