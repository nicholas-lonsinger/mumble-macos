import CommonCrypto
import CryptoKit
import Foundation
import Security

enum PKCS12EncoderError: Error, LocalizedError {
    case privateKeyExport(CFError?)
    case tripleDESFailure(Int32)
    case selfCheckFailed(OSStatus)
    case selfCheckMissingIdentity
    case selfCheckMissingKey

    var errorDescription: String? {
        switch self {
        case .privateKeyExport(let err):
            return "Couldn't export the RSA private key: \(Self.msg(err))"
        case .tripleDESFailure(let status):
            return "3DES encryption failed (CCCryptorStatus \(status))."
        case .selfCheckFailed(let status):
            return "SecPKCS12Import rejected the PKCS#12 we just built: OSStatus \(status)."
        case .selfCheckMissingIdentity:
            return "The PKCS#12 we just built didn't contain an importable identity."
        case .selfCheckMissingKey:
            return "The PKCS#12 we just built imports, but its private key isn't accessible."
        }
    }

    private static func msg(_ err: CFError?) -> String {
        guard let err else { return "unknown" }
        return CFErrorCopyDescription(err) as String? ?? "unknown"
    }
}

/// Builds a PKCS#12 (PFX) blob containing an X.509 cert plus an RSA
/// private key. The key bag is shrouded with pbeWithSHA1And3-KeyTripleDES-CBC
/// (the universally-interoperable legacy PKCS#12 algorithm — what openssl,
/// SecPKCS12Import, and every Mumble-era tool speak). The cert bag is
/// left unencrypted; the outer PFX is MAC-protected with HMAC-SHA1.
///
/// Every built PKCS#12 is round-tripped through SecPKCS12Import before
/// being returned; a failure there means our encoder is wrong, and we
/// want to know at creation time rather than at TLS-handshake time.
enum PKCS12Encoder {
    private static let oidData = "1.2.840.113549.1.7.1"
    private static let oidCertBag = "1.2.840.113549.1.12.10.1.3"
    private static let oidShroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
    private static let oidX509Certificate = "1.2.840.113549.1.9.22.1"
    private static let oidFriendlyName = "1.2.840.113549.1.9.20"
    private static let oidLocalKeyID = "1.2.840.113549.1.9.21"
    private static let oidPBEwithSHA1And3DES = "1.2.840.113549.1.12.1.3"
    private static let oidRSAEncryption = "1.2.840.113549.1.1.1"
    private static let oidSHA1 = "1.3.14.3.2.26"

    static func encode(certificateDER: Data,
                       privateKey: SecKey,
                       password: String,
                       friendlyName: String = "Mumble User",
                       iterations: Int = 2048) throws -> Data {
        var exportErr: Unmanaged<CFError>?
        guard let pkcs1KeyDER = SecKeyCopyExternalRepresentation(privateKey, &exportErr) as Data? else {
            throw PKCS12EncoderError.privateKeyExport(exportErr?.takeRetainedValue())
        }

        // PKCS#8 PrivateKeyInfo wrapping the RSA private key. Everything
        // inside the shrouded key bag is expected to be PKCS#8 by convention.
        let pkcs8KeyDER = DER.sequence([
            DER.integer(0),
            DER.sequence([DER.objectIdentifier(oidRSAEncryption), DER.null()]),
            DER.octetString(pkcs1KeyDER)
        ])

        // SHA-1 of the DER cert. Shared between the cert and key bag
        // attributes so SecPKCS12Import pairs them together.
        let localKeyID = Data(Insecure.SHA1.hash(data: certificateDER))

        let certBag = buildCertBag(certificateDER: certificateDER,
                                   localKeyID: localKeyID,
                                   friendlyName: friendlyName)
        let certSafeContents = DER.sequence([certBag])
        let certContentInfo = idDataContentInfo(enclosing: certSafeContents)

        let keyBag = try buildShroudedKeyBag(pkcs8KeyDER: pkcs8KeyDER,
                                             password: password,
                                             iterations: iterations,
                                             localKeyID: localKeyID,
                                             friendlyName: friendlyName)
        let keySafeContents = DER.sequence([keyBag])
        let keyContentInfo = idDataContentInfo(enclosing: keySafeContents)

        let authSafe = DER.sequence([certContentInfo, keyContentInfo])

        let macSalt = randomBytes(count: 8)
        let macKey = PKCS12KDF.derive(password: password, salt: macSalt,
                                      iterations: iterations, id: 3, length: 20)
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: authSafe,
                                                              using: SymmetricKey(data: macKey)))
        let macData = DER.sequence([
            DER.sequence([
                DER.sequence([DER.objectIdentifier(oidSHA1), DER.null()]),
                DER.octetString(mac)
            ]),
            DER.octetString(macSalt),
            DER.integer(UInt64(iterations))
        ])

        let pfx = DER.sequence([
            DER.integer(3),
            DER.sequence([
                DER.objectIdentifier(oidData),
                DER.explicit(tag: 0, DER.octetString(authSafe))
            ]),
            macData
        ])

        try verifyRoundTrip(pkcs12: pfx, password: password)
        return pfx
    }

    // MARK: - Bag builders

    private static func idDataContentInfo(enclosing content: Data) -> Data {
        DER.sequence([
            DER.objectIdentifier(oidData),
            DER.explicit(tag: 0, DER.octetString(content))
        ])
    }

    private static func buildCertBag(certificateDER: Data,
                                     localKeyID: Data,
                                     friendlyName: String) -> Data {
        let certTypeAndValue = DER.sequence([
            DER.objectIdentifier(oidX509Certificate),
            DER.explicit(tag: 0, DER.octetString(certificateDER))
        ])
        return DER.sequence([
            DER.objectIdentifier(oidCertBag),
            DER.explicit(tag: 0, certTypeAndValue),
            bagAttributes(localKeyID: localKeyID, friendlyName: friendlyName)
        ])
    }

    private static func buildShroudedKeyBag(pkcs8KeyDER: Data,
                                            password: String,
                                            iterations: Int,
                                            localKeyID: Data,
                                            friendlyName: String) throws -> Data {
        let salt = randomBytes(count: 8)
        let encryptionKey = PKCS12KDF.derive(password: password, salt: salt,
                                             iterations: iterations, id: 1, length: 24)
        let iv = PKCS12KDF.derive(password: password, salt: salt,
                                  iterations: iterations, id: 2, length: 8)
        let ciphertext = try tripleDESEncrypt(key: encryptionKey, iv: iv, plaintext: pkcs8KeyDER)

        let encryptedPrivateKeyInfo = DER.sequence([
            DER.sequence([
                DER.objectIdentifier(oidPBEwithSHA1And3DES),
                DER.sequence([
                    DER.octetString(salt),
                    DER.integer(UInt64(iterations))
                ])
            ]),
            DER.octetString(ciphertext)
        ])

        return DER.sequence([
            DER.objectIdentifier(oidShroudedKeyBag),
            DER.explicit(tag: 0, encryptedPrivateKeyInfo),
            bagAttributes(localKeyID: localKeyID, friendlyName: friendlyName)
        ])
    }

    private static func bagAttributes(localKeyID: Data, friendlyName: String) -> Data {
        DER.set([
            DER.sequence([
                DER.objectIdentifier(oidLocalKeyID),
                DER.set([DER.octetString(localKeyID)])
            ]),
            DER.sequence([
                DER.objectIdentifier(oidFriendlyName),
                DER.set([DER.bmpString(friendlyName)])
            ])
        ])
    }

    // MARK: - Crypto

    private static func tripleDESEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        precondition(key.count == kCCKeySize3DES, "3DES key must be 24 bytes")
        precondition(iv.count == kCCBlockSize3DES, "3DES IV must be 8 bytes")
        let bufferCapacity = plaintext.count + kCCBlockSize3DES
        var out = Data(count: bufferCapacity)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            plaintext.withUnsafeBytes { (ptBuf: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (kBuf: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    iv.withUnsafeBytes { (ivBuf: UnsafeRawBufferPointer) -> CCCryptorStatus in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithm3DES),
                                CCOptions(kCCOptionPKCS7Padding),
                                kBuf.baseAddress, key.count,
                                ivBuf.baseAddress,
                                ptBuf.baseAddress, plaintext.count,
                                outBuf.baseAddress, bufferCapacity,
                                &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PKCS12EncoderError.tripleDESFailure(status)
        }
        out.removeSubrange(outLen..<out.count)
        return out
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Self-check

    private static func verifyRoundTrip(pkcs12: Data, password: String) throws {
        // Mirrors IdentityStore.importToIdentity's options exactly — we want
        // the same kind of import we'll actually do at read time.
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecUseDataProtectionKeychain as String: true
        ]
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw PKCS12EncoderError.selfCheckFailed(status)
        }
        guard let arr = items as? [[String: Any]],
              let first = arr.first,
              let anyIdentity = first[kSecImportItemIdentity as String] else {
            throw PKCS12EncoderError.selfCheckMissingIdentity
        }
        let identity = anyIdentity as! SecIdentity
        var keyRef: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &keyRef)
        guard keyStatus == errSecSuccess, keyRef != nil else {
            throw PKCS12EncoderError.selfCheckMissingKey
        }
    }
}

// MARK: - PKCS#12 KDF (RFC 7292 Appendix B)

/// The bespoke key-derivation algorithm PKCS#12 uses for PBE and for the
/// outer MAC key. Not the same as PBKDF2 — it's defined in RFC 7292
/// Appendix B and only shows up inside PKCS#12 files, so no Apple framework
/// exposes it. The whole reason we hand-roll it is because CommonCrypto
/// provides 3DES and CryptoKit provides SHA-1, but neither provides this
/// glue.
enum PKCS12KDF {
    static func derive(password: String,
                       salt: Data,
                       iterations: Int,
                       id: UInt8,
                       length: Int) -> Data {
        let u = 20  // SHA-1 output length
        let v = 64  // SHA-1 block length

        let P = bmpPassword(password)
        let D = Data(repeating: id, count: v)
        let S = fillToMultipleOfBlock(salt, block: v)
        let Pprime = fillToMultipleOfBlock(P, block: v)
        var I = S + Pprime

        let blockCount = (length + u - 1) / u
        var output = Data()

        for _ in 0..<blockCount {
            var A = D + I
            for _ in 0..<iterations {
                A = Data(Insecure.SHA1.hash(data: A))
            }
            output.append(A)

            // Compute (B + 1) as a v-byte big-endian integer, where B is
            // the v-byte expansion of A (repeating + truncation).
            var Bp1 = [UInt8]()
            while Bp1.count < v {
                Bp1.append(contentsOf: [UInt8](A))
            }
            Bp1 = Array(Bp1.prefix(v))
            var carry: UInt16 = 1
            for i in stride(from: v - 1, through: 0, by: -1) {
                let sum = UInt16(Bp1[i]) + carry
                Bp1[i] = UInt8(sum & 0xFF)
                carry = sum >> 8
                if carry == 0 { break }
            }

            // I_j := (I_j + B + 1) mod 2^(v*8), for each v-byte chunk of I.
            var newI = Data()
            var ibytes = [UInt8](I)
            for chunkStart in stride(from: 0, to: ibytes.count, by: v) {
                var chunkCarry: UInt16 = 0
                for i in stride(from: v - 1, through: 0, by: -1) {
                    let idx = chunkStart + i
                    let s = UInt16(ibytes[idx]) + UInt16(Bp1[i]) + chunkCarry
                    ibytes[idx] = UInt8(s & 0xFF)
                    chunkCarry = s >> 8
                }
            }
            newI.append(contentsOf: ibytes)
            I = newI
        }

        return Data(output.prefix(length))
    }

    /// PKCS#12 password = BMPString (UTF-16BE) + two null bytes terminator,
    /// per RFC 7292 Appendix B. The empty-password case is *not* `0x00 0x00`
    /// — RFC 7292 explicitly says "if the password is the empty string,
    /// then P, as well, is the empty string", and SecPKCS12Import enforces
    /// this. Producing a `0x00 0x00` empty password derives a different
    /// KDF key than the verifier expects, and the round-trip self-check
    /// fails with errSecAuthFailed.
    private static func bmpPassword(_ s: String) -> Data {
        if s.isEmpty { return Data() }
        var data = Data()
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v <= 0xFFFF {
                data.append(UInt8(v >> 8))
                data.append(UInt8(v & 0xFF))
            } else {
                let adjusted = v - 0x10000
                let high = UInt32(0xD800) | (adjusted >> 10)
                let low = UInt32(0xDC00) | (adjusted & 0x3FF)
                data.append(UInt8((high >> 8) & 0xFF))
                data.append(UInt8(high & 0xFF))
                data.append(UInt8((low >> 8) & 0xFF))
                data.append(UInt8(low & 0xFF))
            }
        }
        data.append(0x00)
        data.append(0x00)
        return data
    }

    private static func fillToMultipleOfBlock(_ data: Data, block: Int) -> Data {
        if data.isEmpty { return Data() }
        let target = ((data.count + block - 1) / block) * block
        var out = Data()
        out.reserveCapacity(target)
        while out.count < target { out.append(data) }
        return Data(out.prefix(target))
    }
}
