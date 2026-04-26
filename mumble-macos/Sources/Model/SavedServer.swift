import Foundation

/// A bookmarked Mumble server, stored on disk in `Servers.json`.
///
/// The password is **not** part of this struct — it lives in the
/// data-protection keychain via `ServerPasswordStore`, keyed by `id`,
/// and only when `passwordHandling == .useStoredPassword`. Splitting
/// the secret out keeps `Servers.json` shareable (e.g. via iCloud
/// later) without leaking anything sensitive.
struct SavedServer: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Friendly display name — defaults to `host` on creation.
    var label: String
    var host: String
    var port: UInt16
    var username: String
    /// `nil` means the server lives at the top level (ungrouped).
    var groupID: UUID?
    /// Ordering within the parent group (or top level when `groupID == nil`).
    /// Lower comes first.
    var sortIndex: Int
    var lastConnectedAt: Date?
    /// Drives the connect flow's prompt-or-skip decision and the keychain
    /// invariant. See `PasswordHandling` for the contract.
    var passwordHandling: PasswordHandling
    /// Marks an entry that was seeded from a public server list. Drives the
    /// "Refresh Public Servers" replace-by-source behavior in phase 4.
    var publicSource: PublicSource?

    init(
        id: UUID = UUID(),
        label: String,
        host: String,
        port: UInt16,
        username: String,
        groupID: UUID? = nil,
        sortIndex: Int = 0,
        lastConnectedAt: Date? = nil,
        passwordHandling: PasswordHandling = .useStoredPassword,
        publicSource: PublicSource? = nil
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.groupID = groupID
        self.sortIndex = sortIndex
        self.lastConnectedAt = lastConnectedAt
        self.passwordHandling = passwordHandling
        self.publicSource = publicSource
    }
}

/// How the connect flow should treat this bookmark's password.
///
/// Invariant: a keychain entry exists for the bookmark **iff**
/// `passwordHandling == .useStoredPassword`. Save / edit flows must
/// preserve this; the connect flow relies on it (a missing entry under
/// `.useStoredPassword` is a recovery-path signal, not a normal state).
enum PasswordHandling: String, Codable, Sendable, CaseIterable {
    /// Password is held in the data-protection keychain under this
    /// bookmark's id. Connect uses the stored value, no prompt.
    case useStoredPassword
    /// Server doesn't require a password. Connect with `""`, no prompt,
    /// no keychain entry.
    case noPasswordRequired
    /// Always show the password prompt before connecting; never store
    /// what the user types.
    case promptEveryTime
}

enum PublicSource: String, Codable, Sendable, CaseIterable {
    case mumbleInfo
    case mumbleCom
}

/// A user- or system-defined grouping. Servers reference a group via
/// `SavedServer.groupID`; ungrouped servers (`groupID == nil`) sort at
/// the top level alongside the groups themselves.
struct ServerGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    /// Ordering among groups at the top level.
    var sortIndex: Int
    /// Distinguishes user-created groups from system-managed ones. The
    /// "Favorites" group is seeded on first launch and cannot be deleted;
    /// public/imported groups are managed by their respective refresh /
    /// import actions.
    var kind: Kind

    enum Kind: String, Codable, Sendable {
        case favorites
        case user
        case imported
        case publicMumbleInfo
        case publicMumbleCom
    }

    init(
        id: UUID = UUID(),
        name: String,
        isCollapsed: Bool = false,
        sortIndex: Int = 0,
        kind: Kind = .user
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.sortIndex = sortIndex
        self.kind = kind
    }
}
