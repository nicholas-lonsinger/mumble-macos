import XCTest
@testable import mumble_macos

/// Unit tests for `ShortcutsStore`. Each test runs against a unique
/// `UserDefaults` suite so they don't share state with each other or
/// with the user's real preferences.
@MainActor
final class ShortcutsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ShortcutsStoreTests-\(UUID().uuidString)"
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

    // MARK: - First-launch seeding

    func test_firstLaunchSeedsDefaultPushToTalk() {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        XCTAssertEqual(store.bindings.count, 1)
        let binding = store.bindings[0]
        XCTAssertEqual(binding.action, .pushToTalk)
        XCTAssertEqual(binding.trigger, .modifiersOnly(modifiers: [.fn, .control]))
    }

    func test_firstLaunchSeedPersists() {
        // Constructing once seeds defaults; constructing a second store
        // against the same defaults should load (not re-seed) — which means
        // the first construction must have written the seed to disk.
        _ = ShortcutsStore(defaults: defaults, storageKey: "key")
        let second = ShortcutsStore(defaults: defaults, storageKey: "key")
        XCTAssertEqual(second.bindings.count, 1)
        XCTAssertEqual(second.bindings[0].action, .pushToTalk)
    }

    // MARK: - Corrupt-data fallback

    func test_corruptStoredDataFallsBackToDefaults() {
        defaults.set(Data([0xFF, 0xFE, 0xFD]), forKey: "key")
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        // Falls back to seeded defaults rather than crashing or loading
        // an empty list (which would lock the user out of PTT).
        XCTAssertEqual(store.bindings.count, 1)
        XCTAssertEqual(store.bindings[0].action, .pushToTalk)
    }

    func test_corruptStoredDataIsOverwrittenOnLoad() throws {
        defaults.set(Data([0xFF, 0xFE]), forKey: "key")
        _ = ShortcutsStore(defaults: defaults, storageKey: "key")
        // After load, the corrupt blob should be replaced with valid JSON
        // so the next launch reads clean data.
        let raw = try XCTUnwrap(defaults.data(forKey: "key"))
        let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: raw)
        XCTAssertEqual(decoded.count, 1)
    }

    // MARK: - CRUD

    func test_addAppendsAndPersists() throws {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        let binding = ShortcutBinding(action: .muteSelfToggle, trigger: nil)
        store.add(binding)
        XCTAssertEqual(store.bindings.count, 2)
        XCTAssertEqual(store.bindings.last?.id, binding.id)

        // Verify persistence — read raw from defaults.
        let raw = try XCTUnwrap(defaults.data(forKey: "key"))
        let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: raw)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue(decoded.contains(where: { $0.id == binding.id }))
    }

    func test_updateRewritesExistingBinding() throws {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        var binding = store.bindings[0]
        binding.trigger = .key(modifiers: [.shift], keyCode: 0x11, displayName: "T")
        store.update(binding)

        XCTAssertEqual(store.bindings.count, 1)
        XCTAssertEqual(
            store.bindings[0].trigger,
            .key(modifiers: [.shift], keyCode: 0x11, displayName: "T")
        )
    }

    func test_updateOnUnknownIDIsNoOp() {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        let phantom = ShortcutBinding(action: .pushToMute, trigger: nil)
        store.update(phantom)
        XCTAssertEqual(store.bindings.count, 1)
    }

    func test_removeStripsBinding() {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        let id = store.bindings[0].id
        store.remove(id: id)
        XCTAssertTrue(store.bindings.isEmpty)
    }

    func test_restoreDefaultsResetsStore() {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        store.add(ShortcutBinding(action: .deafenSelfToggle, trigger: nil))
        store.remove(id: store.bindings.first!.id) // remove the seeded PTT row
        XCTAssertEqual(store.bindings.count, 1)
        XCTAssertEqual(store.bindings[0].action, .deafenSelfToggle)

        store.restoreDefaults()
        XCTAssertEqual(store.bindings.count, 1)
        XCTAssertEqual(store.bindings[0].action, .pushToTalk)
        XCTAssertEqual(store.bindings[0].trigger, .modifiersOnly(modifiers: [.fn, .control]))
    }

    // MARK: - Notification fan-out

    func test_mutationsPostDidChangeNotification() {
        let store = ShortcutsStore(defaults: defaults, storageKey: "key")
        let expectation = expectation(forNotification: ShortcutsStore.didChangeNotification,
                                      object: store)
        store.add(ShortcutBinding(action: .muteSelfToggle, trigger: nil))
        wait(for: [expectation], timeout: 1.0)
    }
}
