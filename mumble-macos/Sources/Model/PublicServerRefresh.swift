import Foundation
import Observation
import OSLog

/// Coordinates a "Refresh Public Servers" operation: ensures the public
/// group exists, fetches the public list, and replaces the seeded entries
/// in `ServerBookStore`.
///
/// The state machine is observable so any UI surface can watch progress.
/// Currently the only caller is `AppDelegate.refreshPublicServers`, which
/// awaits `run(defaultUsername:)` and presents the result as a sheet.
@MainActor
@Observable
final class PublicServerRefresh {
    /// Shared instance so any future surface that adds a refresh entry
    /// point drives the same state machine — the user shouldn't see two
    /// parallel refreshes if they hit both.
    static let shared = PublicServerRefresh()

    enum Status: Equatable, Sendable {
        case idle
        case running
        case finished(replaced: Int)
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "publist-refresh")
    private let bookStore: ServerBookStore
    private let fetcher: PublicServerListFetcher

    init(bookStore: ServerBookStore = .shared,
         fetcher: PublicServerListFetcher = PublicServerListFetcher()) {
        self.bookStore = bookStore
        self.fetcher = fetcher
    }

    /// Async one-shot refresh. Returns the resulting status so callers
    /// can present a result UI without observing `status` separately.
    /// If a refresh is already running, returns the current status
    /// without starting another.
    @discardableResult
    func run(defaultUsername: String) async -> Status {
        if case .running = status { return status }
        status = .running
        do {
            let entries = try await fetcher.fetch()
            applyEntries(entries, defaultUsername: defaultUsername)
            status = .finished(replaced: entries.count)
            Self.log.info("Refreshed public list — \(entries.count, privacy: .public) entries")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message: message)
            Self.log.error("Public refresh failed: \(message, privacy: .public)")
        }
        return status
    }

    private func applyEntries(_ entries: [PublicServerEntry], defaultUsername: String) {
        let group = ensurePublicGroup()
        let username = defaultUsername.isEmpty ? "Mumble User" : defaultUsername
        // Public-list entries arrive without passwords. Treat them as
        // "no password required" so connecting from a freshly seeded
        // bookmark doesn't always prompt — most public servers are
        // guest-friendly. If a particular one rejects the empty
        // password the user can edit the bookmark to add one.
        let replacements: [SavedServer] = entries.enumerated().map { index, entry in
            SavedServer(
                label: entry.name,
                host: entry.host,
                port: entry.port,
                username: username,
                groupID: group.id,
                sortIndex: index + 1,
                passwordHandling: .noPasswordRequired,
                publicSource: .mumbleInfo
            )
        }
        bookStore.replaceServers(matching: .mumbleInfo, with: replacements)
    }

    /// Public group is system-managed: created lazily on first refresh,
    /// referenced by `kind == .publicMumbleInfo` so a renamed group still
    /// resolves correctly.
    private func ensurePublicGroup() -> ServerGroup {
        if let existing = bookStore.group(of: .publicMumbleInfo) {
            return existing
        }
        let group = ServerGroup(name: "Public Servers", kind: .publicMumbleInfo)
        bookStore.addGroup(group)
        // Re-fetch by kind to get the auto-assigned sortIndex.
        return bookStore.group(of: .publicMumbleInfo) ?? group
    }
}
