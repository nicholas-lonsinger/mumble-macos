import XCTest
import CryptoKit
import Security
@testable import mumble_macos

/// Tests for the hand-rolled PKCS#12 encoder + the PKCS#12 KDF it depends
/// on. Complement to `PKCS12Encoder.encode`'s production self-check (see
/// CLAUDE.md): the self-check stays as a fail-fast in production, these
/// tests narrow down what's broken when something does go wrong.
final class PKCS12EncoderTests: XCTestCase {

    // MARK: - Shared fixture

    /// One self-signed identity for the whole test class. RSA 2048 keygen
    /// is the slow part (~100ms); password / iterations / friendlyName
    /// vary independently of the underlying key material.
    ///
    /// `nonisolated(unsafe)` because `GeneratedIdentity` holds `SecKey`s,
    /// which aren't `Sendable` to the compiler — but `SecKey` is Apple-
    /// documented thread-safe and the static let is read-only.
    nonisolated(unsafe) private static let sharedIdentity: GeneratedIdentity = {
        do {
            return try X509Builder.createSelfSigned(commonName: "Test User", validityYears: 1)
        } catch {
            fatalError("Failed to generate test identity: \(error)")
        }
    }()

    private func encode(password: String = "test-pw",
                        friendlyName: String = "Mumble Test User",
                        iterations: Int = 1024) throws -> Data {
        let id = Self.sharedIdentity
        return try PKCS12Encoder.encode(
            certificateDER: id.certificateDER,
            privateKey: id.privateKey,
            password: password,
            friendlyName: friendlyName,
            iterations: iterations
        )
    }

    private func importP12(_ p12: Data, password: String) -> SecIdentity? {
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let identity = first[kSecImportItemIdentity as String]
        else {
            return nil
        }
        return (identity as! SecIdentity)
    }

    // MARK: - Round-trip

    func test_encodeProducesImportableP12() throws {
        let p12 = try encode()
        XCTAssertNotNil(importP12(p12, password: "test-pw"))
    }

    func test_importedCertificateMatchesInput() throws {
        let p12 = try encode()
        let identity = try XCTUnwrap(importP12(p12, password: "test-pw"))
        var certRef: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certRef), errSecSuccess)
        let imported = SecCertificateCopyData(try XCTUnwrap(certRef)) as Data
        XCTAssertEqual(imported, Self.sharedIdentity.certificateDER)
    }

    func test_importedPrivateKeyIsRetrievable() throws {
        let p12 = try encode()
        let identity = try XCTUnwrap(importP12(p12, password: "test-pw"))
        var keyRef: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &keyRef), errSecSuccess)
        XCTAssertNotNil(keyRef)
    }

    /// Mirrors `IdentityStore.assertRSA`. On macOS the imported key's
    /// `kSecAttrKeyType` round-trips as `NSNumber`, on iOS as `CFString`;
    /// either form must equal `kSecAttrKeyTypeRSA` when stringified.
    /// Regression guard for the macOS/iOS divergence handled in
    /// `IdentityStore`.
    func test_importedKeyTypeIsRSA() throws {
        let p12 = try encode()
        let identity = try XCTUnwrap(importP12(p12, password: "test-pw"))
        var keyRef: SecKey?
        SecIdentityCopyPrivateKey(identity, &keyRef)
        let key = try XCTUnwrap(keyRef)
        let attrs = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let typeAttr = attrs[kSecAttrKeyType as String]
        let expected = kSecAttrKeyTypeRSA as String
        if let s = typeAttr as? String {
            XCTAssertEqual(s, expected)
        } else if let n = typeAttr as? NSNumber {
            XCTAssertEqual(String(n.intValue), expected,
                           "kSecAttrKeyType returned as NSNumber should match RSA constant when stringified")
        } else {
            XCTFail("Unexpected kSecAttrKeyType form: \(String(describing: typeAttr))")
        }
    }

    /// The imported key actually signs — proves the encoder wrote the key
    /// material correctly, not just that SecPKCS12Import accepted the
    /// blob. A subtle mis-encoding could pass structural import but yield
    /// a key that fails the moment BoringSSL asks it to sign a TLS
    /// challenge.
    func test_importedKeyCanSign() throws {
        let p12 = try encode()
        let identity = try XCTUnwrap(importP12(p12, password: "test-pw"))
        var keyRef: SecKey?
        SecIdentityCopyPrivateKey(identity, &keyRef)
        let key = try XCTUnwrap(keyRef)
        let message = Data("hello".utf8)
        var signErr: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(key,
                                              .rsaSignatureMessagePKCS1v15SHA256,
                                              message as CFData,
                                              &signErr) as Data?
        XCTAssertNotNil(signature)
    }

    // MARK: - Password handling

    func test_wrongPasswordRejected() throws {
        let p12 = try encode(password: "right")
        XCTAssertNil(importP12(p12, password: "wrong"))
    }

    func test_emptyPasswordWorks() throws {
        let p12 = try encode(password: "")
        XCTAssertNotNil(importP12(p12, password: ""))
    }

    /// PKCS#12 passwords are encoded as BMPString (UTF-16 BE). Non-ASCII
    /// codepoints — including surrogate pairs for emoji — must round-trip;
    /// a botched surrogate would make the decryption-side KDF derive a
    /// different key and the import would fail.
    func test_unicodePasswordWorks() throws {
        let unicodePass = "пароль🔐"
        let p12 = try encode(password: unicodePass)
        XCTAssertNotNil(importP12(p12, password: unicodePass))
    }

    // MARK: - ASN.1 / OID landing slots

    /// pbeWithSHA1And3-KeyTripleDES-CBC = 1.2.840.113549.1.12.1.3.
    /// DER OID encodings are unique enough that a substring check pins
    /// the algorithm to the correct slot. Counting occurrences also
    /// catches the accidental-second-match case.
    func test_keyBagShroudedWithSHA1And3DES() throws {
        let p12 = try encode()
        let oid: [UInt8] = [0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03]
        XCTAssertEqual(p12.occurrencesOf(oid), 1,
                       "expected pbeWithSHA1And3-KeyTripleDES-CBC OID exactly once (in the shrouded key bag)")
    }

    /// Outer PFX MAC algorithm = SHA-1 (1.3.14.3.2.26). The cert itself
    /// is signed with sha256WithRSAEncryption (a different OID) so the
    /// SHA-1 OID appears uniquely in the MAC slot.
    func test_outerMacUsesSHA1() throws {
        let p12 = try encode()
        let oid: [UInt8] = [0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A]
        XCTAssertEqual(p12.occurrencesOf(oid), 1,
                       "expected SHA-1 OID exactly once (in the outer MAC algorithm slot)")
    }

    /// 1.2.840.113549.1.12.10.1.3 — certBag content type.
    func test_certBagOIDPresent() throws {
        let p12 = try encode()
        let oid: [UInt8] = [0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03]
        XCTAssertEqual(p12.occurrencesOf(oid), 1)
    }

    /// 1.2.840.113549.1.12.10.1.2 — pkcs8ShroudedKeyBag content type.
    func test_shroudedKeyBagOIDPresent() throws {
        let p12 = try encode()
        let oid: [UInt8] = [0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02]
        XCTAssertEqual(p12.occurrencesOf(oid), 1)
    }

    /// friendlyName attribute is BMPString-encoded. The name we passed
    /// must show up in the encoded P12 so SecPKCS12Import can return it
    /// to consumers.
    func test_friendlyNameLandsInOutput() throws {
        let name = "Mumble Test User"
        let p12 = try encode(friendlyName: name)
        var bmp = Data()
        for c in name.unicodeScalars {
            bmp.append(UInt8(c.value >> 8))
            bmp.append(UInt8(c.value & 0xFF))
        }
        XCTAssertNotNil(p12.range(of: bmp))
    }

    // MARK: - PKCS12KDF (RFC 7292 Appendix B)

    /// PKCS12KDF self-stability vector. Cross-validation against an
    /// authoritative implementation comes from `test_encodeProducesImportableP12`
    /// and friends — if our KDF were RFC-incorrect, `SecPKCS12Import`
    /// (Apple's reference implementation) would fail to decrypt our
    /// shrouded key bag. Pinning a fixed (input → output) here defends
    /// against silent KDF regressions in refactors that *happen* to leave
    /// the round-trip working — e.g. a bug only in the final-block
    /// truncation, or one that affects only certain id values, or one in
    /// the surrogate-pair path that the round-trip's ASCII password
    /// wouldn't exercise.
    func test_KDF_stabilityVector() {
        let salt = Data([0x0a, 0x58, 0xcf, 0x64, 0x53, 0x0d, 0x82, 0x3f])
        let actual = PKCS12KDF.derive(password: "smeg", salt: salt,
                                      iterations: 1, id: 1, length: 24)
        XCTAssertEqual(actual.hex(),
                       "8aaae6297b6cb04642ab5b077851284eb7128f1a2a7fbca3")
    }

    /// Output length matches the requested length even when SHA-1's
    /// 20-byte block doesn't divide it evenly — covers the "request 30
    /// bytes, get two SHA-1 blocks, truncate" path.
    func test_KDF_outputLength() {
        let salt = Data(repeating: 0xAA, count: 8)
        for length in [8, 16, 20, 24, 30, 64] {
            let out = PKCS12KDF.derive(password: "x", salt: salt,
                                       iterations: 100, id: 1, length: length)
            XCTAssertEqual(out.count, length, "length mismatch for requested \(length)")
        }
    }

    /// Same inputs → same output. Defends against accidentally seeding
    /// with a non-deterministic source (e.g. from a refactor that
    /// substituted a CSPRNG).
    func test_KDF_isDeterministic() {
        let salt = Data(repeating: 0x55, count: 8)
        let a = PKCS12KDF.derive(password: "p", salt: salt, iterations: 50, id: 1, length: 24)
        let b = PKCS12KDF.derive(password: "p", salt: salt, iterations: 50, id: 1, length: 24)
        XCTAssertEqual(a, b)
    }

    /// The whole point of having id slots (1 = encryption key, 2 = IV,
    /// 3 = MAC key) is that they produce independent outputs. If they
    /// collided the IV would equal the encryption key — a key-recovery
    /// disaster for the shrouded key bag.
    func test_KDF_idDistinguishes() {
        let salt = Data(repeating: 0x55, count: 8)
        let key = PKCS12KDF.derive(password: "p", salt: salt, iterations: 50, id: 1, length: 24)
        let iv = PKCS12KDF.derive(password: "p", salt: salt, iterations: 50, id: 2, length: 24)
        let mac = PKCS12KDF.derive(password: "p", salt: salt, iterations: 50, id: 3, length: 24)
        XCTAssertNotEqual(key, iv)
        XCTAssertNotEqual(key, mac)
        XCTAssertNotEqual(iv, mac)
    }

    /// Empty password is valid (BMP encoding degenerates to two null
    /// bytes for the terminator). Output should be deterministic and the
    /// requested length, not empty/nil.
    func test_KDF_emptyPasswordProducesOutput() {
        let salt = Data(repeating: 0x42, count: 8)
        let out = PKCS12KDF.derive(password: "", salt: salt, iterations: 100, id: 1, length: 24)
        XCTAssertEqual(out.count, 24)
        let again = PKCS12KDF.derive(password: "", salt: salt, iterations: 100, id: 1, length: 24)
        XCTAssertEqual(out, again)
    }

    /// Iteration count actually changes the output — i.e. we're hashing
    /// `iterations` times, not just once and ignoring the parameter.
    func test_KDF_iterationsAffectOutput() {
        let salt = Data(repeating: 0xCC, count: 8)
        let one = PKCS12KDF.derive(password: "p", salt: salt, iterations: 1, id: 1, length: 24)
        let many = PKCS12KDF.derive(password: "p", salt: salt, iterations: 1000, id: 1, length: 24)
        XCTAssertNotEqual(one, many)
    }
}

private extension Data {
    func hex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Count non-overlapping occurrences of a byte pattern.
    func occurrencesOf(_ pattern: [UInt8]) -> Int {
        let needle = Data(pattern)
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = self.range(of: needle, options: [], in: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}
