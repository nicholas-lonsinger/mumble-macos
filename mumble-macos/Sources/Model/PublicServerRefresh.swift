import Foundation
import Observation
import OSLog

/// Coordinates a "Refresh Public Servers" operation: ensures the public
/// group exists, fetches the public list, and replaces the seeded entries
/// in `ServerBookStore`.
///
/// The state machine is observable so the toolbar button can disable
/// itself / show a spinner / display the result.
@MainActor
@Observable
final class PublicServerRefresh {
    /// Shared instance so the toolbar button and the File menu item drive
    /// the same state machine — the user shouldn't see two parallel
    /// refreshes if they hit both surfaces.
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
    private var inFlightTask: Task<Void, Never>?

    init(bookStore: ServerBookStore = .shared,
         fetcher: PublicServerListFetcher = PublicServerListFetcher()) {
        self.bookStore = bookStore
        self.fetcher = fetcher
    }

    /// Triggers a refresh. If one is already running, this no-ops — the
    /// caller wires the button's `disabled` state to `status == .running`
    /// to make this case unreachable in practice.
    func start(defaultUsername: String) {
        if case .running = status { return }
        status = .running
        let task = Task { @MainActor in
            await self.run(defaultUsername: defaultUsername)
        }
        inFlightTask = task
    }

    private func run(defaultUsername: String) async {
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
    }

    private func applyEntries(_ entries: [PublicServerEntry], defaultUsername: String) {
        let group = ensurePublicGroup()
        let username = defaultUsername.isEmpty ? "Mumble User" : defaultUsername
        let replacements: [SavedServer] = entries.enumerated().map { index, entry in
            SavedServer(
                label: entry.name,
                host: entry.host,
                port: entry.port,
                username: username,
                groupID: group.id,
                sortIndex: index + 1,
                rememberPassword: false,
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
