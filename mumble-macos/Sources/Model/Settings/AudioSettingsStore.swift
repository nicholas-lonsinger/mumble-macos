import Foundation
import Observation
import OSLog

/// Persists the user's audio-pipeline preferences.
///
/// Storage: a small handful of scalar values in `UserDefaults`. We don't
/// bundle them under one JSON blob the way `ShortcutsStore` does, because
/// each setting is a primitive and it's nicer to be able to read/clear
/// them individually with `defaults` from the command line.
@MainActor
@Observable
final class AudioSettingsStore {
    static let shared = AudioSettingsStore()

    /// Milliseconds to keep capturing + sending audio after a PTT /
    /// Whisper / Shout key is released. Defends against the AVAudioEngine
    /// input tap delivering audio in ~100 ms chunks (in VMs / over
    /// Bluetooth) — without this linger, the last chunk's worth of
    /// speech is still in flight when the user releases, so the tail of
    /// their last word gets cut. 200 ms comfortably covers a 100 ms tap
    /// cadence; 0 disables the linger and matches the pre-pref behavior.
    var releaseLingerMS: Int {
        didSet {
            guard releaseLingerMS != oldValue else { return }
            persist()
        }
    }

    /// Posted on every mutation so non-SwiftUI observers can re-read.
    /// `MumbleClient` listens for this to push the new value into the
    /// live `VoiceController`.
    static let didChangeNotification = Notification.Name("AudioSettingsStoreDidChange")

    /// Bounds enforced by the Preferences UI; documented here so the
    /// store can clamp on load too (in case a defaults edit out-of-range
    /// sneaks in).
    static let releaseLingerMSRange: ClosedRange<Int> = 0...500
    static let releaseLingerMSDefault: Int = 200

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "audio-settings-store")

    private let defaults: UserDefaults
    private let lingerKey: String

    /// Test seam — production uses `.standard` and the v1 key.
    init(defaults: UserDefaults = .standard,
         lingerKey: String = "audio.releaseLingerMS.v1") {
        self.defaults = defaults
        self.lingerKey = lingerKey
        if let stored = defaults.object(forKey: lingerKey) as? Int {
            self.releaseLingerMS = Self.clampLinger(stored)
        } else {
            self.releaseLingerMS = Self.releaseLingerMSDefault
        }
    }

    private static func clampLinger(_ value: Int) -> Int {
        min(max(value, releaseLingerMSRange.lowerBound), releaseLingerMSRange.upperBound)
    }

    private func persist() {
        let clamped = Self.clampLinger(releaseLingerMS)
        if clamped != releaseLingerMS {
            // Re-entering the setter would loop, but the guard in `didSet`
            // breaks the loop once the value matches.
            releaseLingerMS = clamped
            return
        }
        defaults.set(releaseLingerMS, forKey: lingerKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
