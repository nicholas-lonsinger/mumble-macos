import Foundation

enum ProtobufError: Error, Sendable {
    case truncated
    case malformedVarint
    case invalidWireType(UInt8)
    case unexpectedEndOfMessage
    case stringNotUtf8
    case fieldValueOutOfRange
}

enum ProtoWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtobufReader {
    private let bytes: [UInt8]
    private(set) var index: Int
    private let endIndex: Int

    init(_ data: Data) {
        self.bytes = Array(data)
        self.index = 0
        self.endIndex = bytes.count
    }

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.index = range.lowerBound
        self.endIndex = range.upperBound
    }

    var isAtEnd: Bool { index >= endIndex }
    var remainingCount: Int { endIndex - index }

    mutating func readTag() throws -> (fieldNumber: Int, wireType: ProtoWireType)? {
        guard !isAtEnd else { return nil }
        let raw = try readVarint()
        let rawWire = UInt8(raw & 0x7)
        guard let wireType = ProtoWireType(rawValue: rawWire) else {
            throw ProtobufError.invalidWireType(rawWire)
        }
        let fieldNumber = Int(raw >> 3)
        return (fieldNumber, wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard index < endIndex else { throw ProtobufError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        throw ProtobufError.malformedVarint
    }

    mutating func readFixed32() throws -> UInt32 {
        guard endIndex - index >= 4 else { throw ProtobufError.truncated }
        let v = UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
        index += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard endIndex - index >= 8 else { throw ProtobufError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[index + i]) << (8 * i)
        }
        index += 8
        return v
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readFixed32())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readFixed64())
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    mutating func readInt32() throws -> Int32 {
        Int32(truncatingIfNeeded: try readVarint())
    }

    mutating func readUInt32() throws -> UInt32 {
        let v = try readVarint()
        guard v <= UInt64(UInt32.max) else { throw ProtobufError.fieldValueOutOfRange }
        return UInt32(v)
    }

    mutating func readLengthPrefix() throws -> Int {
        let length = try readVarint()
        guard length <= UInt64(Int.max), Int(length) <= endIndex - index else {
            throw ProtobufError.truncated
        }
        return Int(length)
    }

    mutating func readBytes() throws -> Data {
        let count = try readLengthPrefix()
        let slice = bytes[index..<(index + count)]
        index += count
        return Data(slice)
    }

    mutating func readString() throws -> String {
        let count = try readLengthPrefix()
        let slice = bytes[index..<(index + count)]
        index += count
        guard let s = String(bytes: slice, encoding: .utf8) else {
            throw ProtobufError.stringNotUtf8
        }
        return s
    }

    mutating func readSubMessage() throws -> ProtobufReader {
        let count = try readLengthPrefix()
        let subRange = index..<(index + count)
        index += count
        return ProtobufReader(bytes, range: subRange)
    }

    mutating func skipField(_ wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            guard endIndex - index >= 8 else { throw ProtobufError.truncated }
            index += 8
        case .lengthDelimited:
            let count = try readLengthPrefix()
            index += count
        case .fixed32:
            guard endIndex - index >= 4 else { throw ProtobufError.truncated }
            index += 4
        }
    }
}

struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func writeTag(_ fieldNumber: Int, _ wireType: ProtoWireType) {
        writeVarint(UInt64(fieldNumber) << 3 | UInt64(wireType.rawValue))
    }

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func writeFixed32(_ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func writeFixed64(_ value: UInt64) {
        for i in 0..<8 {
            bytes.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    mutating func writeRawBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func writeRawBytes(_ raw: Data) {
        bytes.append(contentsOf: raw)
    }

    // MARK: - Typed field helpers

    mutating func writeField(_ fieldNumber: Int, uint32 value: UInt32) {
        writeTag(fieldNumber, .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeField(_ fieldNumber: Int, uint64 value: UInt64) {
        writeTag(fieldNumber, .varint)
        writeVarint(value)
    }

    mutating func writeField(_ fieldNumber: Int, int32 value: Int32) {
        writeTag(fieldNumber, .varint)
        // int32 is stored as varint — negative values are sign-extended to 10-byte varints.
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func writeField(_ fieldNumber: Int, bool value: Bool) {
        writeTag(fieldNumber, .varint)
        writeVarint(value ? 1 : 0)
    }

    mutating func writeField(_ fieldNumber: Int, string value: String) {
        writeTag(fieldNumber, .lengthDelimited)
        let utf8 = Array(value.utf8)
        writeVarint(UInt64(utf8.count))
        writeRawBytes(utf8)
    }

    mutating func writeField(_ fieldNumber: Int, data value: Data) {
        writeTag(fieldNumber, .lengthDelimited)
        writeVarint(UInt64(value.count))
        writeRawBytes(value)
    }

    mutating func writeField(_ fieldNumber: Int, float value: Float) {
        writeTag(fieldNumber, .fixed32)
        writeFixed32(value.bitPattern)
    }

    mutating func writeField(_ fieldNumber: Int, message value: Data) {
        writeTag(fieldNumber, .lengthDelimited)
        writeVarint(UInt64(value.count))
        writeRawBytes(value)
    }
}
