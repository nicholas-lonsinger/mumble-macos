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
            // Map the row's password presence to a PasswordHandling mode:
            // a non-empty password means "use stored"; empty means "no
            // password required" (Mumble.app stores blank passwords as
            // empty strings, not NULL — see MumbleAppImporter).
            let initialHandling: PasswordHandling = row.password.isEmpty
                ? .noPasswordRequired
                : .useStoredPassword
            let server = SavedServer(
                label: row.name,
                host: row.host,
                port: row.port,
                username: row.username,
                groupID: group.id,
                passwordHandling: initialHandling
            )
            bookStore.addServer(server)
            if initialHandling == .useStoredPassword {
                do {
                    try passwords.setPassword(row.password, forServer: server.id)
                } catch {
                    Self.log.error("Couldn't store imported password: \(error.localizedDescription, privacy: .public)")
                    // Demote the bookmark to .promptEveryTime — keychain
                    // refused the write so the invariant "useStoredPassword
                    // ⇒ keychain entry exists" wouldn't hold otherwise.
                    var s = server
                    s.passwordHandling = .promptEveryTime
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
