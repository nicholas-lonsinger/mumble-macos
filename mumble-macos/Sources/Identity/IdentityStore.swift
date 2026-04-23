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
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return ClientIdentity(secIdentity: result as! SecIdentity)
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityStoreError.keychain(status, "identity lookup")
        }
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
              let identity = first[kSecImportItemIdentity as String]
        else {
            throw IdentityStoreError.pkcs12MissingIdentity
        }
        let secIdentity = identity as! SecIdentity

        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(secIdentity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            throw IdentityStoreError.keychain(certStatus, "copy certificate from P12 identity")
        }
        var keyRef: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(secIdentity, &keyRef)
        guard keyStatus == errSecSuccess, let key = keyRef else {
            throw IdentityStoreError.pkcs12MissingPrivateKey
        }

        // Fail early if the key isn't something we can store as RSA.
        var cfError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &cfError) as Data? else {
            if let cfError { cfError.release() }
            throw IdentityStoreError.pkcs12UnsupportedKeyType
        }
        let keyAttrs = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let keyType = keyAttrs[kSecAttrKeyType as String] as? String
        guard keyType == (kSecAttrKeyTypeRSA as String) else {
            throw IdentityStoreError.pkcs12UnsupportedKeyType
        }
        let keyBits = (keyAttrs[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 2048

        // Wipe anything we have first so the call is idempotent. Matches the
        // "single identity" v1 invariant.
        try deleteIfPresent()

        try addCertificate(cert)
        try addPrivateKey(keyData, sizeInBits: keyBits)

        Self.log.info("Imported Mumble identity into data-protection keychain.")
    }

    // MARK: - Delete

    func delete() throws {
        try deleteIfPresent(ignoreMissing: false)
        Self.log.info("Deleted Mumble identity from data-protection keychain.")
    }

    private func deleteIfPresent(ignoreMissing: Bool = true) throws {
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrLabel as String: certLabel
        ]
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrApplicationTag as String: keyTag
        ]
        for (query, op) in [(certQuery, "delete certificate"), (keyQuery, "delete private key")] {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound {
                if !ignoreMissing {
                    // Only the explicit delete() cares — importPKCS12 treats the
                    // wipe as best-effort.
                    continue
                }
            } else if status != errSecSuccess {
                throw IdentityStoreError.keychain(status, op)
            }
        }
    }

    // MARK: - Low-level keychain writes

    private func addCertificate(_ cert: SecCertificate) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: certLabel,
            kSecValueRef as String: cert
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status, "add certificate")
        }
    }

    private func addPrivateKey(_ pkcs1Data: Data, sizeInBits: Int) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: sizeInBits,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: pkcs1Data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status, "add private key")
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
