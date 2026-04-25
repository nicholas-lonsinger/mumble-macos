import Foundation

/// A bookmarked Mumble server, stored on disk in `Servers.json`.
///
/// The password is **not** part of this struct — it lives in the
/// data-protection keychain via `ServerPasswordStore`, keyed by `id`.
/// Splitting it out keeps `Servers.json` shareable (e.g. via iCloud later)
/// without leaking secrets, and lets the `rememberPassword` toggle gate
/// keychain writes independently of the bookmark itself.
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
    /// When `true`, a password is stored in the keychain under this server's
    /// id. When toggled to `false`, callers must delete the keychain entry.
    var rememberPassword: Bool
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
        rememberPassword: Bool = true,
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
        self.rememberPassword = rememberPassword
        self.publicSource = publicSource
    }
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
