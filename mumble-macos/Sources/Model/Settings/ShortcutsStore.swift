import Foundation
import Observation
import OSLog

/// Persists the user's shortcut bindings.
///
/// Storage: a JSON-encoded `[ShortcutBinding]` blob in `UserDefaults` under
/// the key `"shortcuts.bindings.v1"`. The binding list is small (a handful of
/// rows) and changes infrequently, so UserDefaults is enough — no separate
/// JSON file needed.
///
/// On first read with no stored data, seeds one default row: Push-to-Talk
/// bound to Fn+Control. This preserves the pre-Preferences-window PTT chord
/// (the previous hardcoded `MainWindowController.installPTTMonitor()`) so
/// existing users see no behavioral change after the upgrade.
@MainActor
@Observable
final class ShortcutsStore {
    static let shared = ShortcutsStore()

    private(set) var bindings: [ShortcutBinding] = []

    /// Posted on every mutation so observers (the dispatcher) can re-read.
    /// `@Observable` already triggers SwiftUI updates; this Notification is
    /// for the AppKit-side `ShortcutDispatcher` which doesn't observe through
    /// SwiftUI.
    static let didChangeNotification = Notification.Name("ShortcutsStoreDidChange")

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "shortcuts-store")

    private let defaults: UserDefaults
    private let storageKey: String

    /// Test seam — production uses `.standard` and the v1 key.
    init(defaults: UserDefaults = .standard,
         storageKey: String = "shortcuts.bindings.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    // MARK: - Mutations

    func add(_ binding: ShortcutBinding) {
        bindings.append(binding)
        persist()
    }

    func update(_ binding: ShortcutBinding) {
        guard let idx = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
        bindings[idx] = binding
        persist()
    }

    func remove(id: UUID) {
        bindings.removeAll(where: { $0.id == id })
        persist()
    }

    func restoreDefaults() {
        bindings = Self.seededDefaults()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            bindings = Self.seededDefaults()
            persist()
            return
        }
        do {
            let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: data)
            bindings = decoded
        } catch {
            // Corrupt stored data shouldn't lock the user out of their PTT key —
            // log loudly, fall back to defaults, and overwrite the bad blob.
            Self.log.error("Failed to decode stored shortcuts (\(data.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public). Resetting to defaults.")
            bindings = Self.seededDefaults()
            persist()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(bindings)
            defaults.set(data, forKey: storageKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } catch {
            Self.log.error("Failed to encode shortcuts: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Defaults

    /// Single default binding: PTT on Fn+Control. Matches the previous
    /// hardcoded chord in `MainWindowController.installPTTMonitor()` so the
    /// upgrade is transparent to existing users.
    private static func seededDefaults() -> [ShortcutBinding] {
        [
            ShortcutBinding(action: .pushToTalk,
                            trigger: .modifiersOnly(modifiers: [.fn, .control]))
        ]
    }
}
