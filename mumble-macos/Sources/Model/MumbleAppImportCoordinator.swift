import Foundation
import OSLog

/// Glues the SQLite reader (`MumbleAppImporter`) to `ServerBookStore` +
/// `ServerPasswordStore`. One-shot, idempotent: re-running over the same
/// `mumble.sqlite` skips entries that already have a matching
/// `(host, port, username)` triplet anywhere in the book — including
/// outside the Imported group, so a user who renames or moves an
/// imported entry doesn't see it duplicated on the next import.
@MainActor
struct MumbleAppImportCoordinator {
    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "mumble-app-import")

    let bookStore: ServerBookStore
    let passwords: ServerPasswordStore
    let importer: MumbleAppImporter

    init(bookStore: ServerBookStore = .shared,
         passwords: ServerPasswordStore = .shared,
         importer: MumbleAppImporter = MumbleAppImporter()) {
        self.bookStore = bookStore
        self.passwords = passwords
        self.importer = importer
    }

    struct Summary: Equatable, Sendable {
        var imported: Int = 0
        var skippedDuplicates: Int = 0
        var passwordWriteFailures: Int = 0
    }

    func run(at url: URL) throws -> Summary {
        let rows = try importer.read(at: url)
        let group = ensureImportedGroup()

        var summary = Summary()
        for row in rows {
            if existsAlready(host: row.host, port: row.port, username: row.username) {
                summary.skippedDuplicates += 1
                continue
            }
            let server = SavedServer(
                label: row.name,
                host: row.host,
                port: row.port,
                username: row.username,
                groupID: group.id,
                rememberPassword: !row.password.isEmpty
            )
            bookStore.addServer(server)
            if !row.password.isEmpty {
                do {
                    try passwords.setPassword(row.password, forServer: server.id)
                } catch {
                    Self.log.error("Couldn't store imported password: \(error.localizedDescription, privacy: .public)")
                    // Toggle off rememberPassword on the saved entry — the
                    // user's keychain didn't accept the write so we'd
                    // otherwise present a stale "remembered" indicator.
                    var s = server
                    s.rememberPassword = false
                    try? bookStore.updateServer(s)
                    summary.passwordWriteFailures += 1
                }
            }
            summary.imported += 1
        }
        Self.log.info("Import summary: imported=\(summary.imported, privacy: .public) skipped=\(summary.skippedDuplicates, privacy: .public) pwFailures=\(summary.passwordWriteFailures, privacy: .public)")
        return summary
    }

    // MARK: - Helpers

    private func existsAlready(host: String, port: UInt16, username: String) -> Bool {
        bookStore.servers.contains { existing in
            existing.host.caseInsensitiveCompare(host) == .orderedSame
                && existing.port == port
                && existing.username == username
        }
    }

    private func ensureImportedGroup() -> ServerGroup {
        if let existing = bookStore.group(of: .imported) {
            return existing
        }
        let group = ServerGroup(name: "Imported", kind: .imported)
        bookStore.addGroup(group)
        return bookStore.group(of: .imported) ?? group
    }
}
