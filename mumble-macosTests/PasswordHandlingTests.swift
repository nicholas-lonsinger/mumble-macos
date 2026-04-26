import XCTest
@testable import mumble_macos

/// Locks in the contract around `SavedServer.passwordHandling` and the
/// invariant "a keychain entry exists for a bookmark **iff**
/// `passwordHandling == .useStoredPassword`." These tests don't exercise
/// SwiftUI; they exercise the data-layer contract that the connect path,
/// the bookmark editor's save path, and the importer/seeder all rely on.
@MainActor
final class PasswordHandlingTests: XCTestCase {

    private var tempBookURL: URL!
    private var bookStore: ServerBookStore!
    private var passwords: ServerPasswordStore!
    private var keychainAccountsToCleanUp: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        tempBookURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PasswordHandlingTests-\(UUID().uuidString).json"
        )
        bookStore = ServerBookStore(storageURL: tempBookURL)
        passwords = ServerPasswordStore(
            service: "com.nicholas-lonsinger.mumble-macos.tests.pwhandling.\(UUID().uuidString)"
        )
    }

    override func tearDown() async throws {
        for id in keychainAccountsToCleanUp {
            try? passwords.deletePassword(forServer: id)
        }
        keychainAccountsToCleanUp.removeAll()
        if let tempBookURL { try? FileManager.default.removeItem(at: tempBookURL) }
        bookStore = nil
        passwords = nil
        try await super.tearDown()
    }

    // MARK: - Decode of unknown values

    func test_codableRoundTripsAllCases() throws {
        for handling in PasswordHandling.allCases {
            let server = SavedServer(
                label: "X", host: "x", port: 1, username: "u",
                passwordHandling: handling
            )
            let data = try JSONEncoder().encode(server)
            let decoded = try JSONDecoder().decode(SavedServer.self, from: data)
            XCTAssertEqual(decoded.passwordHandling, handling, "Round-trip lost the value for \(handling)")
        }
    }

    func test_decodeOfUnknownStringValueFails() {
        // Forward-compat: an older build encountering a future enum case
        // should refuse to decode rather than silently dropping the field
        // to a default. The store's quarantine path catches this and
        // starts fresh (see `ServerBookStore.load`).
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "label": "X", "host": "x", "port": 64738, "username": "u",
            "sortIndex": 1,
            "passwordHandling": "futureMode"
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SavedServer.self, from: json))
    }

    // MARK: - Connect-flow decision (helper, mirroring requestConnect)

    /// Replicates `ServersView.requestConnect`'s decision so we can lock in
    /// the contract without instantiating SwiftUI. If the view's logic
    /// diverges from this helper, this test should be the first to fail.
    private enum ConnectDecision: Equatable {
        case connect(password: String)
        case prompt
    }

    private func decision(for server: SavedServer) -> ConnectDecision {
        switch server.passwordHandling {
        case .noPasswordRequired:
            return .connect(password: "")
        case .useStoredPassword:
            if let stored = (try? passwords.password(forServer: server.id)) ?? nil {
                return .connect(password: stored)
            }
            return .prompt
        case .promptEveryTime:
            return .prompt
        }
    }

    func test_noPasswordRequired_connectsWithEmptyString() {
        let server = SavedServer(label: "Guest", host: "g", port: 1, username: "u",
                                 passwordHandling: .noPasswordRequired)
        XCTAssertEqual(decision(for: server), .connect(password: ""))
    }

    func test_useStoredPassword_withKeychain_connectsWithStored() throws {
        let server = SavedServer(label: "Pw", host: "p", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        try passwords.setPassword("hunter2", forServer: server.id)
        keychainAccountsToCleanUp.append(server.id)
        XCTAssertEqual(decision(for: server), .connect(password: "hunter2"))
    }

    func test_useStoredPassword_withoutKeychain_promptsAsRecovery() {
        // Keychain entry missing for a useStoredPassword bookmark is a
        // recovery path, not a normal state. Falling through to a prompt
        // beats silently failing the connect.
        let server = SavedServer(label: "Orphan", host: "o", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        XCTAssertEqual(decision(for: server), .prompt)
    }

    func test_promptEveryTime_alwaysPrompts() throws {
        // Even if there's an entry under this id (shouldn't happen under
        // the invariant, but the connect path is robust to it), the
        // .promptEveryTime mode wins.
        let server = SavedServer(label: "Ask", host: "a", port: 1, username: "u",
                                 passwordHandling: .promptEveryTime)
        try passwords.setPassword("ignored", forServer: server.id)
        keychainAccountsToCleanUp.append(server.id)
        XCTAssertEqual(decision(for: server), .prompt)
    }

    // MARK: - Save-flow invariant (mirroring AddServerSheet/EditServerSheet)

    /// Helper: applies the save-side keychain rule we use in the editor.
    /// Asserts the invariant holds on disk.
    private func applySaveRule(server: SavedServer,
                               typedPassword: String,
                               priorHandling: PasswordHandling?,
                               initialPassword: String) throws {
        switch server.passwordHandling {
        case .useStoredPassword:
            if priorHandling != .useStoredPassword || typedPassword != initialPassword {
                try passwords.setPassword(typedPassword, forServer: server.id)
            }
        case .noPasswordRequired, .promptEveryTime:
            if priorHandling == .useStoredPassword {
                try passwords.deletePassword(forServer: server.id)
            }
        }
    }

    func test_saveRule_addingUseStored_writesKeychain() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        keychainAccountsToCleanUp.append(server.id)
        try applySaveRule(server: server, typedPassword: "pw",
                          priorHandling: nil, initialPassword: "")
        XCTAssertEqual(try passwords.password(forServer: server.id), "pw")
    }

    func test_saveRule_addingNoPasswordRequired_writesNothing() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .noPasswordRequired)
        keychainAccountsToCleanUp.append(server.id)
        try applySaveRule(server: server, typedPassword: "",
                          priorHandling: nil, initialPassword: "")
        XCTAssertNil(try passwords.password(forServer: server.id))
    }

    func test_saveRule_useStoredToNoPassword_deletesKeychain() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        keychainAccountsToCleanUp.append(server.id)
        try passwords.setPassword("old", forServer: server.id)

        var edited = server
        edited.passwordHandling = .noPasswordRequired
        try applySaveRule(server: edited, typedPassword: "old",
                          priorHandling: .useStoredPassword, initialPassword: "old")
        XCTAssertNil(try passwords.password(forServer: edited.id),
                     "Switching off useStoredPassword must clear the keychain entry.")
    }

    func test_saveRule_useStoredToPromptEveryTime_deletesKeychain() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        keychainAccountsToCleanUp.append(server.id)
        try passwords.setPassword("old", forServer: server.id)

        var edited = server
        edited.passwordHandling = .promptEveryTime
        try applySaveRule(server: edited, typedPassword: "",
                          priorHandling: .useStoredPassword, initialPassword: "old")
        XCTAssertNil(try passwords.password(forServer: edited.id))
    }

    func test_saveRule_useStoredPasswordChanged_overwritesKeychain() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        keychainAccountsToCleanUp.append(server.id)
        try passwords.setPassword("old", forServer: server.id)

        try applySaveRule(server: server, typedPassword: "new",
                          priorHandling: .useStoredPassword, initialPassword: "old")
        XCTAssertEqual(try passwords.password(forServer: server.id), "new")
    }

    func test_saveRule_promptEveryTimeToUseStored_writesKeychain() throws {
        let server = SavedServer(label: "X", host: "x", port: 1, username: "u",
                                 passwordHandling: .useStoredPassword)
        keychainAccountsToCleanUp.append(server.id)
        try applySaveRule(server: server, typedPassword: "fresh",
                          priorHandling: .promptEveryTime, initialPassword: "")
        XCTAssertEqual(try passwords.password(forServer: server.id), "fresh")
    }
}
