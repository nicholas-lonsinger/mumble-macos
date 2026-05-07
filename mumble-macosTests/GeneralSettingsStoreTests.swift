import XCTest
@testable import mumble_macos

/// Unit tests for `GeneralSettingsStore`. Each test gets a unique
/// `UserDefaults` suite, and the `onDisable` closure is stubbed so we
/// never reach into the real keychain via `LastConnectedServerStore`
/// (those suites are CI-skipped — see CLAUDE memory "CI skips
/// keychain-coupled test suites").
@MainActor
final class GeneralSettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = "general.reconnectOnLaunch.test"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GeneralSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - First-launch default

    func test_firstLaunchDefaultsToOff() {
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        XCTAssertFalse(store.reconnectOnLaunch)
    }

    func test_firstLaunchDoesNotPersistDefault() {
        _ = GeneralSettingsStore(defaults: defaults,
                                 reconnectKey: key,
                                 onDisable: {})
        XCTAssertNil(defaults.object(forKey: key))
    }

    // MARK: - Load existing

    func test_loadsExistingTrue() {
        defaults.set(true, forKey: key)
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        XCTAssertTrue(store.reconnectOnLaunch)
    }

    func test_loadsExistingFalse() {
        defaults.set(false, forKey: key)
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        XCTAssertFalse(store.reconnectOnLaunch)
    }

    // MARK: - Mutation persists

    func test_mutationPersists() throws {
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        store.reconnectOnLaunch = true
        let stored = try XCTUnwrap(defaults.object(forKey: key) as? Bool)
        XCTAssertTrue(stored)
    }

    func test_settingSameValueDoesNotRePersist() {
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        store.reconnectOnLaunch = true
        // Sentinel-flip the stored value behind the store's back; if the
        // setter no-ops on equal-assignment as advertised, the sentinel
        // survives the redundant write.
        defaults.set(false, forKey: key)
        store.reconnectOnLaunch = true
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }

    // MARK: - Disable callback

    func test_togglingOffFiresOnDisable() {
        var disableCount = 0
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: { disableCount += 1 })
        store.reconnectOnLaunch = true
        XCTAssertEqual(disableCount, 0,
                       "Enabling shouldn't trigger the kill-switch callback.")
        store.reconnectOnLaunch = false
        XCTAssertEqual(disableCount, 1,
                       "Disabling should fire onDisable so the persisted record is wiped.")
    }

    func test_togglingOnDoesNotFireOnDisable() {
        var disableCount = 0
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: { disableCount += 1 })
        store.reconnectOnLaunch = true
        XCTAssertEqual(disableCount, 0)
    }

    func test_redundantOffDoesNotFireOnDisable() {
        // Default is false; setting it to false again should no-op and
        // not fire the disable callback (which would clear the keychain
        // unnecessarily).
        var disableCount = 0
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: { disableCount += 1 })
        store.reconnectOnLaunch = false
        XCTAssertEqual(disableCount, 0)
    }

    // MARK: - Notification fan-out

    func test_mutationPostsDidChangeNotification() {
        let store = GeneralSettingsStore(defaults: defaults,
                                         reconnectKey: key,
                                         onDisable: {})
        let expectation = expectation(forNotification: GeneralSettingsStore.didChangeNotification,
                                      object: store)
        store.reconnectOnLaunch = true
        wait(for: [expectation], timeout: 1.0)
    }
}
