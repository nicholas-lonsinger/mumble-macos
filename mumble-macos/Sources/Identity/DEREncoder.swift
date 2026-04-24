import Foundation

/// Minimal DER (ASN.1 Distinguished Encoding Rules) writer, scoped to the
/// types `X509Builder` and `PKCS12Encoder` emit. Not a general-purpose
/// ASN.1 library — if you find yourself needing a new tag here, that's a
/// decision to make deliberately, not a bug to patch around.
///
/// Inputs that would produce malformed DER (negative lengths, zero-arc
/// OIDs) trap via `precondition`. Every call site in this project builds
/// fixed, known-shape structures, so a trap means a programmer error.
enum DER {
    private static let tagBoolean: UInt8 = 0x01
    private static let tagInteger: UInt8 = 0x02
    private static let tagBitString: UInt8 = 0x03
    private static let tagOctetString: UInt8 = 0x04
    private static let tagNull: UInt8 = 0x05
    private static let tagOID: UInt8 = 0x06
    private static let tagUTF8String: UInt8 = 0x0C
    private static let tagPrintableString: UInt8 = 0x13
    private static let tagUTCTime: UInt8 = 0x17
    private static let tagGeneralizedTime: UInt8 = 0x18
    private static let tagSequence: UInt8 = 0x30
    private static let tagSet: UInt8 = 0x31

    // MARK: - Primitives

    static func boolean(_ value: Bool) -> Data {
        tlv(tag: tagBoolean, content: Data([value ? 0xFF : 0x00]))
    }

    static func null() -> Data {
        Data([tagNull, 0x00])
    }

    /// DER INTEGER from unsigned big-endian bytes. Strips redundant leading
    /// zeros and prepends 0x00 if the high bit is set (INTEGER is signed in
    /// ASN.1; without the pad a multi-byte modulus would encode as negative).
    static func integer(unsignedBytes: Data) -> Data {
        var bytes = Data(stripLeadingZeros(bytesOf: unsignedBytes))
        if bytes.isEmpty { bytes = Data([0x00]) }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tlv(tag: tagInteger, content: bytes)
    }

    static func integer(_ value: UInt64) -> Data {
        if value == 0 {
            return tlv(tag: tagInteger, content: Data([0x00]))
        }
        var v = value
        var bytes = Data()
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tlv(tag: tagInteger, content: bytes)
    }

    static func objectIdentifier(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        precondition(arcs.count >= 2, "OID requires at least two arcs")
        var body = Data()
        body.append(UInt8(arcs[0] * 40 + arcs[1]))
        for arc in arcs.dropFirst(2) {
            body.append(contentsOf: base128(arc))
        }
        return tlv(tag: tagOID, content: body)
    }

    /// BIT STRING whose payload is a whole number of bytes.
    static func bitString(_ bytes: Data) -> Data {
        var content = Data([0x00]) // zero unused trailing bits
        content.append(bytes)
        return tlv(tag: tagBitString, content: content)
    }

    static func octetString(_ bytes: Data) -> Data {
        tlv(tag: tagOctetString, content: bytes)
    }

    static func utf8String(_ s: String) -> Data {
        tlv(tag: tagUTF8String, content: Data(s.utf8))
    }

    static func printableString(_ s: String) -> Data {
        tlv(tag: tagPrintableString, content: Data(s.utf8))
    }

    /// RFC 5280 §4.1.2.5: UTCTime for years 1950–2049 inclusive,
    /// GeneralizedTime from 2050 onwards. We emit whichever the date
    /// falls into so a 20-year validity starting today still parses as
    /// a valid X.509 cert.
    static func x509Time(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        let m = c.month ?? 1, d = c.day ?? 1
        let hh = c.hour ?? 0, mm = c.minute ?? 0, ss = c.second ?? 0
        if year >= 1950 && year < 2050 {
            let yy = year % 100
            let s = String(format: "%02d%02d%02d%02d%02d%02dZ", yy, m, d, hh, mm, ss)
            return tlv(tag: tagUTCTime, content: Data(s.utf8))
        } else {
            let s = String(format: "%04d%02d%02d%02d%02d%02dZ", year, m, d, hh, mm, ss)
            return tlv(tag: tagGeneralizedTime, content: Data(s.utf8))
        }
    }

    // MARK: - Constructors

    static func sequence(_ items: [Data]) -> Data {
        var content = Data()
        for item in items { content.append(item) }
        return tlv(tag: tagSequence, content: content)
    }

    /// DER SET. Caller is responsible for sorting the elements if this is
    /// a SET OF (DER requires ascending encoding order) — the shapes we
    /// build here are always single-element SETs, so no sort needed.
    static func set(_ items: [Data]) -> Data {
        var content = Data()
        for item in items { content.append(item) }
        return tlv(tag: tagSet, content: content)
    }

    /// Context-specific tagged wrapper, always constructed.
    /// Used for X.509 [0] version, [3] extensions, etc.
    static func explicit(tag: UInt8, _ inner: Data) -> Data {
        let t: UInt8 = 0xA0 | (tag & 0x1F)
        return tlv(tag: t, content: inner)
    }

    /// Context-specific tagged wrapper, primitive or constructed per caller.
    /// Used for PKCS#12 [0] content inside ContentInfo, etc.
    static func implicit(tag: UInt8, constructed: Bool, content: Data) -> Data {
        var t: UInt8 = 0x80 | (tag & 0x1F)
        if constructed { t |= 0x20 }
        return tlv(tag: t, content: content)
    }

    // MARK: - Internals

    private static func tlv(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        out.append(encodedLength(content.count))
        out.append(content)
        return out
    }

    private static func encodedLength(_ length: Int) -> Data {
        precondition(length >= 0, "DER length must be non-negative")
        if length < 128 { return Data([UInt8(length)]) }
        var v = length
        var bytes = [UInt8]()
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        var out = Data([0x80 | UInt8(bytes.count)])
        out.append(contentsOf: bytes)
        return out
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0x00] }
        var v = value
        var out: [UInt8] = []
        while v > 0 {
            out.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        for i in 0..<(out.count - 1) { out[i] |= 0x80 }
        return out
    }

    private static func stripLeadingZeros(bytesOf data: Data) -> [UInt8] {
        var bytes = [UInt8](data)
        while bytes.count > 1, bytes[0] == 0x00 {
            bytes.removeFirst()
        }
        return bytes
    }
}
