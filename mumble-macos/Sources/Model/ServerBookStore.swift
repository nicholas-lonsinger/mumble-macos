import Foundation
import Observation
import OSLog

/// On-disk format for `Servers.json`. The struct itself is the file: a single
/// top-level object with `version`, `groups`, and `servers`. `version` exists
/// so we can migrate the file forward later without guessing.
private struct ServerBookFile: Codable {
    var version: Int
    var groups: [ServerGroup]
    var servers: [SavedServer]
}

/// Errors surfaced by `ServerBookStore`. Disk failures are recoverable in the
/// sense that the store falls back to an empty book; we only throw when a
/// caller explicitly asks for an operation that can't be honored (e.g.
/// deleting the always-present Favorites group).
enum ServerBookStoreError: Error, LocalizedError {
    case favoritesGroupNotDeletable
    case unknownGroup(UUID)
    case unknownServer(UUID)

    var errorDescription: String? {
        switch self {
        case .favoritesGroupNotDeletable:
            return "The Favorites group cannot be deleted."
        case .unknownGroup(let id):
            return "No group with id \(id)."
        case .unknownServer(let id):
            return "No server with id \(id)."
        }
    }
}

/// Persists the user's saved servers + groups as a JSON file.
///
/// Storage layout:
///
/// - File: `<Application Support>/Servers.json` (the sandboxed app-specific
///   directory; macOS rewrites this to the container's view).
/// - Format: a single `ServerBookFile` JSON object.
/// - Atomicity: every mutation rewrites the file via `Data.write(to:options:.atomic)`.
///
/// The store is `@MainActor` because it's read by SwiftUI views; mutations
/// happen on the main actor, the file write is synchronous (small file,
/// rare writes — 100 servers in JSON is < 30 KB).
///
/// On first launch, the store seeds a single "Favorites" group of kind
/// `.favorites`. That group is treated as undeletable by the UI; if the
/// file ever loses it (corruption, manual edit), `load()` re-creates it.
@MainActor
@Observable
final class ServerBookStore {
    static let shared = ServerBookStore()

    private(set) var groups: [ServerGroup] = []
    private(set) var servers: [SavedServer] = []

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "server-book")
    private static let fileVersion = 1
    private let storageURL: URL

    /// Test seam — production uses `defaultStorageURL`. Tests pass a temp URL.
    init(storageURL: URL = ServerBookStore.defaultStorageURL) {
        self.storageURL = storageURL
        load()
    }

    // MARK: - Default location

    nonisolated static var defaultStorageURL: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Servers.json", isDirectory: false)
    }

    // MARK: - Server CRUD

    func addServer(_ server: SavedServer) {
        var s = server
        if s.sortIndex == 0 {
            s.sortIndex = nextSortIndex(in: server.groupID)
        }
        servers.append(s)
        save()
    }

    func updateServer(_ server: SavedServer) throws {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else {
            throw ServerBookStoreError.unknownServer(server.id)
        }
        servers[idx] = server
        save()
    }

    func removeServer(id: UUID) throws {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else {
            throw ServerBookStoreError.unknownServer(id)
        }
        servers.remove(at: idx)
        save()
    }

    func server(id: UUID) -> SavedServer? {
        servers.first(where: { $0.id == id })
    }

    /// All servers in `groupID`, sorted by `sortIndex` then label. Pass `nil`
    /// for the top-level (ungrouped) servers.
    func servers(in groupID: UUID?) -> [SavedServer] {
        servers
            .filter { $0.groupID == groupID }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }

    /// Replace every server matching `source` with the given list. Used by
    /// the public-server refresh in phase 4. Servers the user has moved out
    /// of the seeded groups (i.e. their `publicSource` was cleared) are
    /// untouched.
    func replaceServers(matching source: PublicSource, with replacements: [SavedServer]) {
        servers.removeAll(where: { $0.publicSource == source })
        servers.append(contentsOf: replacements)
        save()
    }

    // MARK: - Reorder / move

    /// Moves `serverID` into `groupID` (pass `nil` for top level), placing it
    /// immediately after `afterServerID`. Pass `afterServerID == nil` to put
    /// it at the start. The destination group is renumbered contiguously
    /// after the move so sortIndex stays gap-free.
    ///
    /// Anchor lookup is destination-restricted: if `afterServerID` exists
    /// but isn't actually in `groupID`, we treat it as "no anchor" and
    /// place at the start. That's the right behavior for cross-group
    /// drags where the source row's position has no meaning in the
    /// destination.
    func moveServer(_ serverID: UUID, toGroup groupID: UUID?, afterServerID: UUID?) throws {
        guard servers.contains(where: { $0.id == serverID }) else {
            throw ServerBookStoreError.unknownServer(serverID)
        }
        // Re-resolve the moving server each access — the rest of `servers`
        // gets renumbered below and we want the latest copy.
        guard let moving = servers.first(where: { $0.id == serverID }) else {
            throw ServerBookStoreError.unknownServer(serverID)
        }

        var ordered = servers
            .filter { $0.groupID == groupID && $0.id != serverID }
            .sorted { $0.sortIndex < $1.sortIndex }

        let insertIndex: Int = {
            guard let anchor = afterServerID,
                  let anchorIdx = ordered.firstIndex(where: { $0.id == anchor })
            else { return 0 }
            return anchorIdx + 1
        }()

        var movedCopy = moving
        movedCopy.groupID = groupID
        ordered.insert(movedCopy, at: insertIndex)

        // Renumber sortIndex contiguously starting at 1 so dragging tens
        // of times doesn't grow the indexes unboundedly.
        for (i, item) in ordered.enumerated() {
            if let idx = servers.firstIndex(where: { $0.id == item.id }) {
                servers[idx].sortIndex = i + 1
                servers[idx].groupID = groupID
            }
        }
        save()
    }

    /// Reorders top-level groups. Places `groupID` immediately after
    /// `afterGroupID` (`nil` = at the start). Renumbers sortIndex.
    func moveGroup(_ groupID: UUID, afterGroupID: UUID?) throws {
        guard groups.contains(where: { $0.id == groupID }) else {
            throw ServerBookStoreError.unknownGroup(groupID)
        }
        guard let moving = groups.first(where: { $0.id == groupID }) else {
            throw ServerBookStoreError.unknownGroup(groupID)
        }

        var ordered = groups
            .filter { $0.id != groupID }
            .sorted { $0.sortIndex < $1.sortIndex }

        let insertIndex: Int = {
            guard let anchor = afterGroupID,
                  let anchorIdx = ordered.firstIndex(where: { $0.id == anchor })
            else { return 0 }
            return anchorIdx + 1
        }()
        ordered.insert(moving, at: insertIndex)

        for (i, g) in ordered.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                groups[idx].sortIndex = i + 1
            }
        }
        save()
    }

    // MARK: - Group CRUD

    func addGroup(_ group: ServerGroup) {
        var g = group
        if g.sortIndex == 0 {
            g.sortIndex = nextGroupSortIndex()
        }
        groups.append(g)
        save()
    }

    func updateGroup(_ group: ServerGroup) throws {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else {
            throw ServerBookStoreError.unknownGroup(group.id)
        }
        groups[idx] = group
        save()
    }

    /// Removes `id` and unlinks every server inside it (sets `groupID = nil`).
    /// Throws if the group is the always-present Favorites group.
    func removeGroup(id: UUID) throws {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else {
            throw ServerBookStoreError.unknownGroup(id)
        }
        if groups[idx].kind == .favorites {
            throw ServerBookStoreError.favoritesGroupNotDeletable
        }
        for i in servers.indices where servers[i].groupID == id {
            servers[i].groupID = nil
        }
        groups.remove(at: idx)
        save()
    }

    func group(id: UUID) -> ServerGroup? {
        groups.first(where: { $0.id == id })
    }

    func group(of kind: ServerGroup.Kind) -> ServerGroup? {
        groups.first(where: { $0.kind == kind })
    }

    /// Top-level entries (groups + ungrouped servers), sorted together by
    /// `sortIndex`. Used by the Servers window's source list.
    var topLevelGroupsSorted: [ServerGroup] {
        groups.sorted { $0.sortIndex < $1.sortIndex }
    }

    // MARK: - Load / save

    private func load() {
        do {
            let data = try Data(contentsOf: storageURL)
            let file = try JSONDecoder().decode(ServerBookFile.self, from: data)
            self.groups = file.groups
            self.servers = file.servers
            ensureFavoritesGroup()
            Self.log.info("Loaded server book: \(self.groups.count) groups, \(self.servers.count) servers")
        } catch CocoaError.fileReadNoSuchFile {
            // First launch: seed the file from scratch.
            seedFreshBook()
        } catch let error as DecodingError {
            // Corruption — keep the bad file as a sidecar so the user can
            // recover edits manually, and start fresh. Better than crashing.
            Self.log.error("Servers.json decode failed: \(String(describing: error), privacy: .public). Renaming and starting fresh.")
            quarantineCorruptFile()
            seedFreshBook()
        } catch {
            Self.log.error("Servers.json read failed: \(error.localizedDescription, privacy: .public). Starting fresh in memory.")
            self.groups = []
            self.servers = []
            ensureFavoritesGroup()
        }
    }

    private func seedFreshBook() {
        self.groups = []
        self.servers = []
        ensureFavoritesGroup()
        save()
    }

    private func ensureFavoritesGroup() {
        if !groups.contains(where: { $0.kind == .favorites }) {
            groups.insert(
                ServerGroup(name: "Favorites", isCollapsed: false, sortIndex: 0, kind: .favorites),
                at: 0
            )
        }
    }

    private func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = storageURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: storageURL, to: backup)
    }

    private func save() {
        let file = ServerBookFile(
            version: Self.fileVersion,
            groups: groups,
            servers: servers
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.log.error("Servers.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func nextSortIndex(in groupID: UUID?) -> Int {
        let max = servers.filter { $0.groupID == groupID }.map(\.sortIndex).max() ?? 0
        return max + 1
    }

    private func nextGroupSortIndex() -> Int {
        let max = groups.map(\.sortIndex).max() ?? 0
        return max + 1
    }
}
