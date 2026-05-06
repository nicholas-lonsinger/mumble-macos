import XCTest
@testable import mumble_macos

/// Unit tests for `AudioSettingsStore`. Each test runs against a unique
/// `UserDefaults` suite so they don't share state with each other or with
/// the user's real preferences.
@MainActor
final class AudioSettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = "audio.releaseLingerMS.test"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AudioSettingsStoreTests-\(UUID().uuidString)"
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

    func test_firstLaunchUsesDefault() {
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(store.releaseLingerMS, AudioSettingsStore.releaseLingerMSDefault)
    }

    func test_firstLaunchDoesNotPersistDefault() {
        // Constructing the store with no stored value should leave defaults
        // untouched — we only write on mutation. This way a user who never
        // visits the Audio tab doesn't accumulate a UserDefaults entry just
        // from the app booting.
        _ = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertNil(defaults.object(forKey: key))
    }

    // MARK: - Load existing

    func test_loadsExistingStoredValue() {
        defaults.set(150, forKey: key)
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(store.releaseLingerMS, 150)
    }

    // MARK: - Clamp on load

    func test_clampsValueAboveRangeOnLoad() {
        defaults.set(9999, forKey: key)
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(store.releaseLingerMS,
                       AudioSettingsStore.releaseLingerMSRange.upperBound)
    }

    func test_clampsValueBelowRangeOnLoad() {
        defaults.set(-50, forKey: key)
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(store.releaseLingerMS,
                       AudioSettingsStore.releaseLingerMSRange.lowerBound)
    }

    func test_acceptsBoundaryValuesUnchanged() {
        defaults.set(AudioSettingsStore.releaseLingerMSRange.lowerBound, forKey: key)
        let lower = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(lower.releaseLingerMS,
                       AudioSettingsStore.releaseLingerMSRange.lowerBound)

        defaults.set(AudioSettingsStore.releaseLingerMSRange.upperBound, forKey: key)
        let upper = AudioSettingsStore(defaults: defaults, lingerKey: key)
        XCTAssertEqual(upper.releaseLingerMS,
                       AudioSettingsStore.releaseLingerMSRange.upperBound)
    }

    // MARK: - Mutation persists + clamps

    func test_mutationPersists() throws {
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        store.releaseLingerMS = 350
        let stored = try XCTUnwrap(defaults.object(forKey: key) as? Int)
        XCTAssertEqual(stored, 350)
    }

    func test_mutationOutsideRangeIsClampedAndPersisted() throws {
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        store.releaseLingerMS = 10_000
        XCTAssertEqual(store.releaseLingerMS,
                       AudioSettingsStore.releaseLingerMSRange.upperBound)
        let stored = try XCTUnwrap(defaults.object(forKey: key) as? Int)
        XCTAssertEqual(stored, AudioSettingsStore.releaseLingerMSRange.upperBound)
    }

    func test_settingSameValueDoesNotRePersist() {
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        store.releaseLingerMS = 150
        // Sentinel-write a different value directly to defaults; if the
        // setter no-ops on equal-assignment as advertised, the sentinel
        // survives the redundant write.
        defaults.set(-1, forKey: key)
        store.releaseLingerMS = 150
        XCTAssertEqual(defaults.object(forKey: key) as? Int, -1)
    }

    // MARK: - Notification fan-out

    func test_mutationPostsDidChangeNotification() {
        let store = AudioSettingsStore(defaults: defaults, lingerKey: key)
        let expectation = expectation(forNotification: AudioSettingsStore.didChangeNotification,
                                      object: store)
        store.releaseLingerMS = 250
        wait(for: [expectation], timeout: 1.0)
    }
}
