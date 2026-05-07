import Foundation
import OSLog
import Security

/// Persists the parameters of the most recent successful connection so
/// the app can re-establish it on next launch if the user has the
/// "Reconnect to last server" preference enabled.
///
/// Storage split, same reasoning as `ServerPasswordStore`:
///
/// - Non-secret bits (host, port, username, channel path) → JSON in
///   `UserDefaults`. Inspectable with `defaults read` if needed.
/// - Password → data-protection keychain (`kSecUseDataProtectionKeychain:
///   true`). Touching the legacy login keychain from a sandboxed app has
///   already cost a developer signing cert once; CLAUDE.md → "Identity /
///   keychain" calls this rule out explicitly.
///
/// The store is a singleton because it's hit from app-scope places
/// (`MumbleClient`, `AppDelegate`, the Preferences toggle's clear path).
/// `init` is non-private so tests *could* construct an isolated instance,
/// though we don't currently exercise the keychain path in CI — those
/// suites are skipped on GitHub Actions per the project's keychain
/// coupling rules.
@MainActor
final class LastConnectedServerStore {
    static let shared = LastConnectedServerStore()

    /// Non-secret connection bits we persist. The password rides alongside
    /// in the keychain; loaders return both or `nil`.
    struct Record: Codable, Equatable, Sendable {
        var host: String
        var port: UInt16
        var username: String
        /// Carried through so a connection that originated from a
        /// `mumble://host/Channel/Sub` URL still lands the user in the
        /// same channel after auto-reconnect. Empty means "wherever the
        /// server places me".
        var desiredChannelPath: [String]
    }

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "last-connected-store")

    private let defaults: UserDefaults
    private let recordKey: String
    private let service: String
    private let account: String

    init(defaults: UserDefaults = .standard,
         recordKey: String = "lastConnectedServer.v1",
         service: String = "com.nicholas-lonsinger.mumble-macos.last-connected-password",
         account: String = "default") {
        self.defaults = defaults
        self.recordKey = recordKey
        self.service = service
        self.account = account
    }

    // MARK: - Public API

    /// Persists `record` and `password` together. Called from
    /// `MumbleClient` after `ServerSync` lands successfully — only when
    /// the reconnect-on-launch toggle is on, so users who haven't opted
    /// in never get a password parked in the keychain.
    func save(_ record: Record, password: String) {
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: recordKey)
        } catch {
            Self.log.error("Failed to encode last-connected record: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try writePassword(password)
        } catch {
            Self.log.error("Failed to store last-connected password in keychain: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the record + password if both are present, else `nil`.
    /// "Either piece missing" is treated as "no record" — partial state
    /// shouldn't trigger a half-baked auto-reconnect attempt.
    func load() -> (record: Record, password: String)? {
        guard let data = defaults.data(forKey: recordKey) else { return nil }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            Self.log.error("Failed to decode last-connected record: \(error.localizedDescription, privacy: .public). Clearing.")
            clear()
            return nil
        }
        let password: String?
        do {
            password = try readPassword()
        } catch {
            Self.log.error("Failed to read last-connected password: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let password else { return nil }
        return (record, password)
    }

    /// Removes both halves. Called on user-initiated disconnect (so a
    /// deliberately-left server doesn't auto-reconnect on next launch),
    /// and when the user toggles the reconnect preference off.
    func clear() {
        defaults.removeObject(forKey: recordKey)
        do {
            try deletePasswordIfPresent()
        } catch {
            Self.log.error("Failed to clear last-connected password: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Keychain plumbing

    private func writePassword(_ password: String) throws {
        try deletePasswordIfPresent()
        guard let data = password.data(using: .utf8) else {
            throw LastConnectedServerStoreError.notUTF8
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
            throw LastConnectedServerStoreError.keychain(status, "store last-connected password")
        }
    }

    private func readPassword() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else {
                throw LastConnectedServerStoreError.notUTF8
            }
            return string
        default:
            throw LastConnectedServerStoreError.keychain(status, "fetch last-connected password")
        }
    }

    private func deletePasswordIfPresent() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw LastConnectedServerStoreError.keychain(status, "delete last-connected password")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum LastConnectedServerStoreError: Error, LocalizedError {
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
