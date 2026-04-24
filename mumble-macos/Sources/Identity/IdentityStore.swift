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
    case blobDecode
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
        case .blobDecode:
            return "Couldn't decode the stored identity blob."
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

/// Persists the user's single Mumble client identity in the data-protection
/// keychain.
///
/// We store the PKCS#12 blob + its password as a single generic-password
/// keychain item (value is a small JSON envelope) and re-import through
/// `SecPKCS12Import` each time we need a `SecIdentity`. That's the only
/// path that reliably yields a `SecIdentity` whose private key is
/// retrievable by BoringSSL when the TLS challenge block fires — the
/// "add cert + add key separately, pair later" path returns identities
/// that look fine to the cert-side APIs but blow up the moment
/// `SecIdentityCopyPrivateKey` is called (NULL key → CFRetain crash).
///
/// The re-import per TLS handshake is cheap and has the nice property
/// that the private key only lives in memory for the duration of a
/// connection attempt.
@MainActor
final class IdentityStore {
    static let shared = IdentityStore()

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "identity")

    /// Keychain service + account key under which the envelope is stored.
    private let service = "com.nicholas-lonsinger.mumble-macos.identity"
    private let account = "default"

    private init() {}

    // MARK: - Read

    /// Re-imports the stored PKCS#12 and returns a fully-formed
    /// `SecIdentity`. Returns nil if nothing is stored.
    func currentIdentity() throws -> ClientIdentity? {
        guard let blob = try storedEnvelope() else { return nil }
        return try importToIdentity(blob.pkcs12, password: blob.password)
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

    // MARK: - Import

    func importPKCS12(_ data: Data, password: String) throws {
        // Validate by importing once before we commit it to the keychain.
        // Also fails fast if it's not an RSA key (Mumble only supports RSA).
        let identity = try importToIdentity(data, password: password)
        try assertRSA(identity)

        let envelope = Envelope(pkcs12: data, password: password)
        let json = try JSONEncoder().encode(envelope)

        try deleteIfPresent()

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: json
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status, "store identity envelope")
        }
        Self.log.info("Stored Mumble identity envelope in data-protection keychain.")
    }

    // MARK: - Create

    /// Generates a self-signed RSA identity and persists it. The PKCS#12
    /// envelope's internal password is random — the user never sees it
    /// because they never need to. If/when they export, they'll pick
    /// their own password and we'll re-wrap at that point.
    func createNewIdentity(commonName: String = "Mumble User",
                           validityYears: Int = 20) throws {
        let generated = try X509Builder.createSelfSigned(
            commonName: commonName,
            validityYears: validityYears
        )
        let internalPassword = Self.randomInternalPassword()
        let p12 = try PKCS12Encoder.encode(
            certificateDER: generated.certificateDER,
            privateKey: generated.privateKey,
            password: internalPassword,
            friendlyName: commonName
        )
        try importPKCS12(p12, password: internalPassword)
        Self.log.info("Created fresh self-signed Mumble identity (CN=\(commonName, privacy: .public)).")
    }

    /// 32-byte random, hex-encoded. Stored alongside the P12 in the
    /// envelope — its only job is to be unguessable; it never leaves
    /// the data-protection keychain.
    private static func randomInternalPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Delete

    func delete() throws {
        let query = envelopeQuery()
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status, "delete identity envelope")
        }
        Self.log.info("Deleted Mumble identity envelope from data-protection keychain.")
    }

    private func deleteIfPresent() throws {
        let query = envelopeQuery()
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw IdentityStoreError.keychain(status, "reset identity envelope")
        }
    }

    // MARK: - Stored envelope

    private struct Envelope: Codable {
        let pkcs12: Data
        let password: String
    }

    private func envelopeQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func storedEnvelope() throws -> Envelope? {
        var query = envelopeQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else { throw IdentityStoreError.blobDecode }
            return try JSONDecoder().decode(Envelope.self, from: data)
        default:
            throw IdentityStoreError.keychain(status, "fetch identity envelope")
        }
    }

    // MARK: - PKCS#12 → SecIdentity

    private func importToIdentity(_ p12: Data, password: String) throws -> ClientIdentity {
        var itemsRef: CFArray?
        // kSecUseDataProtectionKeychain: true makes SecPKCS12Import behave like
        // iOS — parse in memory and return the items, no side-effect into the
        // user's login keychain. Without this flag macOS silently drops cert
        // and key items into login.keychain-db every time we connect.
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &itemsRef)
        guard status == errSecSuccess else {
            throw IdentityStoreError.pkcs12(status)
        }
        guard let items = itemsRef as? [[String: Any]], !items.isEmpty,
              let first = items.first,
              let identityAny = first[kSecImportItemIdentity as String]
        else {
            throw IdentityStoreError.pkcs12MissingIdentity
        }
        let identity = identityAny as! SecIdentity

        // Make sure the identity we return actually has a usable private
        // key — a bare SecIdentityCreateWithCertificate hand-back can
        // claim an identity but then hand out NULL to BoringSSL later.
        var keyRef: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &keyRef)
        guard keyStatus == errSecSuccess, keyRef != nil else {
            throw IdentityStoreError.pkcs12MissingPrivateKey
        }

        return ClientIdentity(secIdentity: identity)
    }

    private func assertRSA(_ identity: ClientIdentity) throws {
        var keyRef: SecKey?
        let status = SecIdentityCopyPrivateKey(identity.secIdentity, &keyRef)
        guard status == errSecSuccess, let key = keyRef else {
            throw IdentityStoreError.pkcs12MissingPrivateKey
        }
        let attrs = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let rsaValue = kSecAttrKeyTypeRSA as String // "42" on Apple platforms
        let isRSA: Bool = {
            if let s = attrs[kSecAttrKeyType as String] as? String { return s == rsaValue }
            if let n = attrs[kSecAttrKeyType as String] as? NSNumber,
               let expected = Int(rsaValue) {
                return n.intValue == expected
            }
            return false
        }()
        guard isRSA else {
            throw IdentityStoreError.pkcs12UnsupportedKeyType
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
    /// (seconds since 2001-01-01) wrapped in `CFNumber`.
    private static func absoluteTimeDate(_ entry: [String: Any]?) -> Date? {
        guard let entry else { return nil }
        if let number = entry[kSecPropertyKeyValue as String] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }
}
