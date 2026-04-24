import CryptoKit
import Foundation
import Security

enum X509BuilderError: Error, LocalizedError {
    case keyGeneration(CFError?)
    case publicKeyMissing
    case publicKeyExport(CFError?)
    case signing(CFError?)
    case invalidGeneratedCertificate

    var errorDescription: String? {
        switch self {
        case .keyGeneration(let err):
            return "RSA key generation failed: \(Self.msg(err))"
        case .publicKeyMissing:
            return "Couldn't derive the public key from the new private key."
        case .publicKeyExport(let err):
            return "Couldn't export the generated public key: \(Self.msg(err))"
        case .signing(let err):
            return "Certificate signing failed: \(Self.msg(err))"
        case .invalidGeneratedCertificate:
            return "The generated certificate bytes couldn't be parsed by SecCertificateCreateWithData."
        }
    }

    private static func msg(_ err: CFError?) -> String {
        guard let err else { return "unknown" }
        return CFErrorCopyDescription(err) as String? ?? "unknown"
    }
}

struct GeneratedIdentity {
    let certificateDER: Data
    /// Ephemeral RSA private key — never persisted to any keychain by
    /// `X509Builder`. The caller is responsible for packaging it into a
    /// PKCS#12 and handing it off to `IdentityStore`.
    let privateKey: SecKey
    let publicKey: SecKey
    let notBefore: Date
    let notAfter: Date
}

/// Builds a self-signed X.509 v3 certificate suitable for Mumble client
/// authentication. Defaults mirror the legacy Mumble client: CN "Mumble
/// User", RSA 2048, 20-year validity, sha256WithRSAEncryption signature.
enum X509Builder {
    private static let oidRSAEncryption = "1.2.840.113549.1.1.1"
    private static let oidSHA256WithRSA = "1.2.840.113549.1.1.11"
    private static let oidCN = "2.5.4.3"
    private static let oidKeyUsage = "2.5.29.15"
    private static let oidExtendedKeyUsage = "2.5.29.37"
    private static let oidSubjectKeyIdentifier = "2.5.29.14"
    private static let oidAuthorityKeyIdentifier = "2.5.29.35"
    private static let oidExtKeyUsageClientAuth = "1.3.6.1.5.5.7.3.2"

    static func createSelfSigned(commonName: String,
                                 validityYears: Int) throws -> GeneratedIdentity {
        let (privateKey, publicKey) = try generateRSAKeyPair(bits: 2048)

        var exportErr: Unmanaged<CFError>?
        guard let rsaPublicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &exportErr) as Data? else {
            throw X509BuilderError.publicKeyExport(exportErr?.takeRetainedValue())
        }

        let subjectPublicKeyInfo = DER.sequence([
            algorithmIdentifier(oid: oidRSAEncryption, params: DER.null()),
            DER.bitString(rsaPublicKeyDER)
        ])

        // Back-date notBefore a few minutes so clock skew on the far side
        // of a handshake doesn't reject a cert the user just created.
        let now = Date()
        let notBefore = now.addingTimeInterval(-300)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let notAfter = cal.date(byAdding: .year, value: validityYears, to: now)
            ?? now.addingTimeInterval(TimeInterval(validityYears) * 365 * 86400)

        let name = DER.sequence([
            DER.set([
                DER.sequence([
                    DER.objectIdentifier(oidCN),
                    DER.utf8String(commonName)
                ])
            ])
        ])

        let serial = DER.integer(unsignedBytes: randomSerialBytes())

        // SubjectKeyIdentifier = SHA-1 of the DER-encoded RSAPublicKey bytes
        // (RFC 5280 §4.2.1.2 method 1, applied to the BIT STRING value).
        let ski = Data(Insecure.SHA1.hash(data: rsaPublicKeyDER))

        let extensions = DER.explicit(tag: 3, DER.sequence([
            extensionEntry(
                oid: oidKeyUsage,
                critical: true,
                // digitalSignature(0), keyEncipherment(2) → bits 0+2 set → 0xA0,
                // three trailing bits unused.
                value: DER.bitString(Data([0xA0]), unusedBits: 5)
            ),
            extensionEntry(
                oid: oidExtendedKeyUsage,
                critical: false,
                value: DER.sequence([DER.objectIdentifier(oidExtKeyUsageClientAuth)])
            ),
            extensionEntry(
                oid: oidSubjectKeyIdentifier,
                critical: false,
                value: DER.octetString(ski)
            ),
            extensionEntry(
                oid: oidAuthorityKeyIdentifier,
                critical: false,
                // AuthorityKeyIdentifier ::= SEQUENCE { [0] IMPLICIT KeyIdentifier OPTIONAL, ... }
                value: DER.sequence([
                    DER.implicit(tag: 0, constructed: false, content: ski)
                ])
            )
        ]))

        let tbs = DER.sequence([
            DER.explicit(tag: 0, DER.integer(2)), // version v3
            serial,
            algorithmIdentifier(oid: oidSHA256WithRSA, params: DER.null()),
            name,   // issuer == subject (self-signed)
            DER.sequence([DER.x509Time(notBefore), DER.x509Time(notAfter)]),
            name,
            subjectPublicKeyInfo,
            extensions
        ])

        var signErr: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &signErr
        ) as Data? else {
            throw X509BuilderError.signing(signErr?.takeRetainedValue())
        }

        let certDER = DER.sequence([
            tbs,
            algorithmIdentifier(oid: oidSHA256WithRSA, params: DER.null()),
            DER.bitString(signature)
        ])

        // Self-check: make sure the bytes actually parse as an X.509 cert.
        // Catches encoder bugs at creation time instead of leaving them to
        // surface as opaque PKCS#12 / TLS failures later.
        guard SecCertificateCreateWithData(nil, certDER as CFData) != nil else {
            throw X509BuilderError.invalidGeneratedCertificate
        }

        return GeneratedIdentity(
            certificateDER: certDER,
            privateKey: privateKey,
            publicKey: publicKey,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    // MARK: - Internals

    private static func generateRSAKeyPair(bits: Int) throws -> (SecKey, SecKey) {
        // isPermanent:false keeps the key in-memory; no keychain side effect.
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
            kSecAttrIsPermanent as String: false
        ]
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw X509BuilderError.keyGeneration(err?.takeRetainedValue())
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw X509BuilderError.publicKeyMissing
        }
        return (privateKey, publicKey)
    }

    private static func randomSerialBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7F          // force positive (INTEGER high bit)
        if bytes[0] == 0 { bytes[0] = 0x01 } // avoid all-zero serial
        return Data(bytes)
    }

    private static func algorithmIdentifier(oid: String, params: Data) -> Data {
        DER.sequence([DER.objectIdentifier(oid), params])
    }

    private static func extensionEntry(oid: String, critical: Bool, value: Data) -> Data {
        var parts: [Data] = [DER.objectIdentifier(oid)]
        if critical { parts.append(DER.boolean(true)) }
        parts.append(DER.octetString(value))
        return DER.sequence(parts)
    }
}
