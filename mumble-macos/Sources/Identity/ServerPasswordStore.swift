import Foundation
import OSLog
import Security

/// Errors surfaced by `ServerPasswordStore`.
enum ServerPasswordStoreError: Error, LocalizedError {
    case keychain(OSStatus, String)
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .keychain(let status, let op):
            let detail: String = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
            return "Keychain error during \(op): OSStatus \(status) (\(detail))."
        case .notUTF8:
            return "Stored password was not valid UTF-8."
        }
    }
}

/// Persists per-server passwords in the data-protection keychain.
///
/// One generic-password item per `SavedServer.id`. The store **only** touches
/// the data-protection keychain (`kSecUseDataProtectionKeychain: true`) — see
/// CLAUDE.md, "Identity / keychain": touching the legacy login keychain from
/// a sandboxed app risks deleting unrelated items belonging to the user (we
/// already lost a developer signing cert that way once).
///
/// The service string is unique to the server-password store so passwords
/// can't collide with `IdentityStore`'s own envelope item.
final class ServerPasswordStore: @unchecked Sendable {
    static let shared = ServerPasswordStore()

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "server-password")
    private let service: String

    /// Test seam — production uses the well-known service string. Tests pass
    /// a unique string per test so they don't collide with each other or
    /// with production data.
    init(service: String = "com.nicholas-lonsinger.mumble-macos.server-password") {
        self.service = service
    }

    // MARK: - Per-server password

    /// Writes (or replaces) the password for the given server. The keychain
    /// item is created with `kSecAttrAccessibleWhenUnlocked` — the app is
    /// foreground-only, so post-first-unlock semantics buy us nothing.
    func setPassword(_ password: String, forServer id: UUID) throws {
        try setPassword(password, account: id.uuidString)
    }

    func password(forServer id: UUID) throws -> String? {
        try password(account: id.uuidString)
    }

    func deletePassword(forServer id: UUID) throws {
        try deletePassword(account: id.uuidString)
    }

    // MARK: - Internals

    private func setPassword(_ password: String, account: String) throws {
        try deletePasswordIfPresent(account: account)
        guard let data = password.data(using: .utf8) else {
            throw ServerPasswordStoreError.notUTF8
        }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ServerPasswordStoreError.keychain(status, "store password for \(account)")
        }
    }

    private func password(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else {
                throw ServerPasswordStoreError.notUTF8
            }
            return string
        default:
            throw ServerPasswordStoreError.keychain(status, "fetch password for \(account)")
        }
    }

    private func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw ServerPasswordStoreError.keychain(status, "delete password for \(account)")
        }
    }

    private func deletePasswordIfPresent(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw ServerPasswordStoreError.keychain(status, "reset password for \(account)")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
