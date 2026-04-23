import CryptoKit
import Foundation
import OSLog
import Security

/// Errors surfaced by `IdentityStore`.
enum IdentityStoreError: Error, LocalizedError {
    case keychain(OSStatus, String)
    case pkcs12(OSStatus)
    case pkcs12EmptyResult
    case pkcs12MissingIdentity
    case pkcs12MissingPrivateKey
    case pkcs12UnsupportedKeyType
    case certDecode
    case noIdentity

    var errorDescription: String? {
        switch self {
        case .keychain(let status, let op):
            return "Keychain error during \(op): OSStatus \(status) (\(Self.secError(status)))."
        case .pkcs12(let status):
            return "PKCS#12 import failed: OSStatus \(status) (\(Self.secError(status)))."
        case .pkcs12EmptyResult:
            return "The PKCS#12 file did not contain any items."
        case .pkcs12MissingIdentity:
            return "The PKCS#12 file did not contain a certificate + private-key pair."
        case .pkcs12MissingPrivateKey:
            return "Could not extract the private key from the PKCS#12 file."
        case .pkcs12UnsupportedKeyType:
            return "Only RSA private keys are supported."
        case .certDecode:
            return "The certificate in the keychain could not be decoded."
        case .noIdentity:
            return "No Mumble identity is stored."
        }
    }

    private static func secError(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "unknown"
    }
}

/// Sendable wrapper around a `SecIdentity`. Swift 6 strict concurrency won't
/// let a bare `SecIdentity` cross an isolation boundary; `SecIdentity` values
/// are immutable CF types so marking the holder `@unchecked Sendable` is safe.
struct ClientIdentity: @unchecked Sendable {
    let secIdentity: SecIdentity
}

/// A small view of the current identity for display in the UI.
struct StoredIdentitySummary: Sendable, Equatable {
    /// CN from the cert's subject. "(no common name)" if absent.
    let commonName: String
    /// SHA-256 of the DER-encoded cert — what we display for verification.
    let sha256Fingerprint: String
    /// SHA-1 of the DER-encoded cert — the hash Mumble servers historically key on.
    let sha1Fingerprint: String
    let notBefore: Date
    let notAfter: Date
    /// DER bytes, handy for code that needs to hand them to another framework.
    let certificateDER: Data
}

/// Persists the user's single Mumble client identity (cert + RSA key) in the
/// data-protection keychain — the iOS-style per-app keychain scoped by team
/// ID + bundle ID + code signature, so nothing else on the Mac can read it and
/// the user is never prompted for ACL access.
///
/// We store two linked items:
///   - `kSecClassCertificate` (the X.509 cert, labelled)
///   - `kSecClassKey` (the RSA private key, tagged)
/// and retrieve them as a `SecIdentity` via `kSecClassIdentity`, which pairs
/// them automatically by public-key hash.
@MainActor
final class IdentityStore {
    static let shared = IdentityStore()

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "identity")

    /// User-visible label on the cert item; also what we query by.
    private let certLabel = "Mumble Identity"
    /// Opaque tag on the key item. Never displayed; matches by equality.
    private let keyTag = "com.nicholas-lonsinger.mumble-macos.identity.key".data(using: .utf8)!

    private init() {}

    // MARK: - Read

    func currentIdentity() throws -> ClientIdentity? {
        // SecItemCopyMatching(kSecClassIdentity, kSecUseDataProtectionKeychain:
        // true) reliably returns errSecItemNotFound on macOS even when a
        // matching cert + private key are both present. So we fetch the cert
        // by label and ask SecIdentityCreateWithCertificate to locate the
        // matching private key by public-key hash.
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true
        ]
        var certResult: CFTypeRef?
        let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &certResult)
        switch certStatus {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            break
        default:
            throw IdentityStoreError.keychain(certStatus, "identity lookup (cert)")
        }
        let cert = certResult as! SecCertificate
        var identity: SecIdentity?
        let idStatus = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard idStatus == errSecSuccess, let identity else {
            // Cert is here but the key's missing — treat as no identity.
            if idStatus == errSecItemNotFound { return nil }
            throw IdentityStoreError.keychain(idStatus, "pair cert with private key")
        }
        return ClientIdentity(secIdentity: identity)
    }

    func currentSummary() throws -> StoredIdentitySummary? {
        guard let client = try currentIdentity() else { return nil }
        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(client.secIdentity, &certRef)
        guard status == errSecSuccess, let cert = certRef else {
            throw IdentityStoreError.keychain(status, "copy identity certificate")
        }
        return try Self.makeSummary(from: cert)
    }

    // MARK: - Import PKCS#12

    func importPKCS12(_ data: Data, password: String) throws {
        var itemsRef: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &itemsRef)
        guard status == errSecSuccess else {
            throw IdentityStoreError.pkcs12(status)
        }
        guard let items = itemsRef as? [[String: Any]], !items.isEmpty else {
            throw IdentityStoreError.pkcs12EmptyResult
        }
        guard let first = items.first,
              let identityAny = first[kSecImportItemIdentity as String]
        else {
            throw IdentityStoreError.pkcs12MissingIdentity
        }
        let secIdentity = identityAny as! SecIdentity

        // Verify the key is RSA — Mumble only supports RSA identities.
        // kSecAttrKeyType comes back as NSNumber on macOS but CFString on iOS;
        // accept both.
        var keyRef: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(secIdentity, &keyRef)
        guard keyStatus == errSecSuccess, let key = keyRef else {
            throw IdentityStoreError.pkcs12MissingPrivateKey
        }
        let keyAttrs = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let isRSA: Bool = {
            let rsaCFString = kSecAttrKeyTypeRSA as String // "42"
            if let s = keyAttrs[kSecAttrKeyType as String] as? String { return s == rsaCFString }
            if let n = keyAttrs[kSecAttrKeyType as String] as? NSNumber,
               let expected = Int(rsaCFString) {
                return n.intValue == expected
            }
            return false
        }()
        guard isRSA else {
            throw IdentityStoreError.pkcs12UnsupportedKeyType
        }

        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(secIdentity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            throw IdentityStoreError.keychain(certStatus, "copy certificate from P12 identity")
        }

        // Wipe anything we have first so the call is idempotent. Matches the
        // "single identity" v1 invariant.
        try deleteIfPresent()

        // Add cert and key as separate items in the data-protection keychain.
        // Adding via the full SecIdentity ref doesn't consistently register
        // both halves on macOS; splitting the call makes each side explicit
        // and lets us tag the key with our own kSecAttrApplicationTag for
        // reliable deletion.
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: certLabel
        ]
        let certAdd = SecItemAdd(addCert as CFDictionary, nil)
        guard certAdd == errSecSuccess else {
            throw IdentityStoreError.keychain(certAdd, "add certificate")
        }
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrLabel as String: certLabel
        ]
        let keyAdd = SecItemAdd(addKey as CFDictionary, nil)
        guard keyAdd == errSecSuccess else {
            throw IdentityStoreError.keychain(keyAdd, "add private key")
        }

        Self.log.info("Imported Mumble identity into data-protection keychain.")
    }

    // MARK: - Delete

    func delete() throws {
        try deleteIfPresent(ignoreMissing: false)
        Self.log.info("Deleted Mumble identity from data-protection keychain.")
    }

    private func deleteIfPresent(ignoreMissing: Bool = true) throws {
        // Look up the identity first. SecItemDelete with kSecValueRef is the
        // reliable way to remove the private key: when SecItemAdd inserts a
        // key via a SecIdentity ref, label/tag attributes don't propagate to
        // the underlying key item, so label-/tag-based queries can miss it.
        if let client = try? currentIdentity() {
            var key: SecKey?
            SecIdentityCopyPrivateKey(client.secIdentity, &key)
            var cert: SecCertificate?
            SecIdentityCopyCertificate(client.secIdentity, &cert)
            if let key {
                let status = SecItemDelete([
                    kSecValueRef as String: key,
                    kSecUseDataProtectionKeychain as String: true
                ] as CFDictionary)
                if status != errSecSuccess, status != errSecItemNotFound, !ignoreMissing {
                    throw IdentityStoreError.keychain(status, "delete private key")
                }
            }
            if let cert {
                let status = SecItemDelete([
                    kSecValueRef as String: cert,
                    kSecUseDataProtectionKeychain as String: true
                ] as CFDictionary)
                if status != errSecSuccess, status != errSecItemNotFound, !ignoreMissing {
                    throw IdentityStoreError.keychain(status, "delete certificate")
                }
            }
        }
        // Sweep any leftover item with our label/tag — covers orphans from a
        // partial add. Scoped to the data-protection keychain so we can't
        // reach into the login keychain even by accident.
        let sweeps: [[String: Any]] = [
            [
                kSecClass as String: kSecClassCertificate,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrLabel as String: certLabel
            ],
            [
                kSecClass as String: kSecClassKey,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrApplicationTag as String: keyTag
            ]
        ]
        for q in sweeps {
            let status = SecItemDelete(q as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, !ignoreMissing {
                throw IdentityStoreError.keychain(status, "sweep delete")
            }
        }
    }

    // MARK: - Cert → summary

    private static func makeSummary(from cert: SecCertificate) throws -> StoredIdentitySummary {
        let der = SecCertificateCopyData(cert) as Data

        let commonName: String = {
            var cn: CFString?
            let status = SecCertificateCopyCommonName(cert, &cn)
            if status == errSecSuccess, let cn = cn as String? {
                return cn
            }
            return "(no common name)"
        }()

        var validity: (Date, Date) = (.distantPast, .distantPast)
        if let values = SecCertificateCopyValues(cert,
                                                 [kSecOIDX509V1ValidityNotBefore,
                                                  kSecOIDX509V1ValidityNotAfter] as CFArray,
                                                 nil) as? [String: [String: Any]] {
            if let notBefore = absoluteTimeDate(values[kSecOIDX509V1ValidityNotBefore as String]) {
                validity.0 = notBefore
            }
            if let notAfter = absoluteTimeDate(values[kSecOIDX509V1ValidityNotAfter as String]) {
                validity.1 = notAfter
            }
        }

        let sha256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return StoredIdentitySummary(
            commonName: commonName,
            sha256Fingerprint: sha256,
            sha1Fingerprint: sha1,
            notBefore: validity.0,
            notAfter: validity.1,
            certificateDER: der
        )
    }

    /// `SecCertificateCopyValues` hands validity dates back as `CFAbsoluteTime`
    /// (seconds since 2001-01-01) wrapped in `CFNumber`. Unwrap through both
    /// layers of dictionaries.
    private static func absoluteTimeDate(_ entry: [String: Any]?) -> Date? {
        guard let entry else { return nil }
        if let number = entry[kSecPropertyKeyValue as String] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }
}
