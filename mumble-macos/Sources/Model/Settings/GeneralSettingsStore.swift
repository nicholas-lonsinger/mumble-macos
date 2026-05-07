import Foundation
import Observation
import OSLog

/// Persists the user's "general" preferences — currently just the
/// reconnect-on-launch toggle. Each setting is its own scalar in
/// `UserDefaults` (rather than bundled into one JSON blob), so they're
/// individually inspectable / clearable with the `defaults` CLI.
@MainActor
@Observable
final class GeneralSettingsStore {
    static let shared = GeneralSettingsStore()

    /// When true, `AppDelegate` re-establishes the most recent successful
    /// connection on app launch. The "most recent" record is captured by
    /// `LastConnectedServerStore` and is cleared on user-initiated
    /// disconnect — so the auto-reconnect only fires if the user quit the
    /// app while still connected.
    var reconnectOnLaunch: Bool {
        didSet {
            guard reconnectOnLaunch != oldValue else { return }
            persist()
            if !reconnectOnLaunch {
                // Toggle-off doubles as a kill switch for the persisted
                // record — otherwise the password would sit in the
                // keychain after the user said "stop doing this."
                onDisable()
            }
        }
    }

    static let didChangeNotification = Notification.Name("GeneralSettingsStoreDidChange")

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "general-settings-store")

    private let defaults: UserDefaults
    private let reconnectKey: String
    private let onDisable: @MainActor () -> Void

    /// Test seam — production uses `.standard`, the v1 key, and the real
    /// `LastConnectedServerStore`. Tests inject a no-op `onDisable` so they
    /// never touch the keychain.
    init(defaults: UserDefaults = .standard,
         reconnectKey: String = "general.reconnectOnLaunch.v1",
         onDisable: @MainActor @escaping () -> Void = { LastConnectedServerStore.shared.clear() }) {
        self.defaults = defaults
        self.reconnectKey = reconnectKey
        self.onDisable = onDisable
        if let stored = defaults.object(forKey: reconnectKey) as? Bool {
            self.reconnectOnLaunch = stored
        } else {
            self.reconnectOnLaunch = false
        }
    }

    private func persist() {
        defaults.set(reconnectOnLaunch, forKey: reconnectKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
