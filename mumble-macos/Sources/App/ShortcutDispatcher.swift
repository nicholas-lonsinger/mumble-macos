import AppKit
import Foundation
import OSLog

/// Owns the input monitors and routes keyboard / mouse events to action
/// handlers on `MumbleClient` according to the user's `ShortcutBinding`s.
///
/// One paired (local + global) `NSEvent` monitor is installed per event
/// family we care about: `.flagsChanged`, key down/up, mouse down/up. The
/// local-monitor closures `return event` unmodified — per spec, **no
/// suppression**: bound keys still type into focused fields, bound mouse
/// buttons still click through. The global monitors are observe-only by
/// design.
///
/// On every event, the dispatcher updates its internal "what's currently
/// held" state, then iterates the binding list and computes which bindings
/// match. Bindings that newly match fire `onPress`; bindings that newly stop
/// matching fire `onRelease`. This unified diff handles all three trigger
/// families and naturally covers edge cases (e.g. releasing a modifier
/// that was part of a key chord → release the binding).
///
/// First global key/modifier event triggers macOS's Input Monitoring TCC
/// prompt; mouse-only bindings work without prompting.
@MainActor
final class ShortcutDispatcher {
    private weak var client: MumbleClient?
    private let store: ShortcutsStore

    private var localMonitors: [Any] = []
    private var globalMonitors: [Any] = []
    private var storeObserver: NSObjectProtocol?

    /// What's currently held. Recomputed from each event's `modifierFlags`,
    /// since `.flagsChanged` doesn't tell us *which* modifier changed —
    /// only the new total mask.
    private var activeModifiers: ShortcutModifiers = []
    private var pressedKeys: Set<UInt16> = []
    private var pressedMouseButtons: Set<Int> = []
    /// Hold-action bindings with an open press. Used to diff per-event.
    private var firedBindingIDs: Set<UUID> = []
    /// Set during the Preferences capture flow so live shortcuts don't fire
    /// while the user is binding a new chord. The capture UI suppresses the
    /// captured event itself, but our local monitor was installed first and
    /// would otherwise still process the press → fire a binding the user
    /// is currently editing.
    private var isPaused = false

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "shortcuts")

    init(client: MumbleClient, store: ShortcutsStore) {
        self.client = client
        self.store = store
        installMonitors()
        observeStoreChanges()
    }

    /// Explicit teardown. Not called from `deinit` because Swift 6 strict
    /// concurrency disallows touching non-`Sendable` actor-isolated state
    /// from a nonisolated deinit, and the monitor handles + observer token
    /// are `Any` / `NSObjectProtocol`. The dispatcher is at app scope
    /// (`MainWindowController`, kept alive by `AppDelegate`), so leak risk
    /// is bounded — call this only if you intend to drop the dispatcher
    /// before app exit.
    func invalidate() {
        for monitor in localMonitors { NSEvent.removeMonitor(monitor) }
        for monitor in globalMonitors { NSEvent.removeMonitor(monitor) }
        localMonitors.removeAll()
        globalMonitors.removeAll()
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
            self.storeObserver = nil
        }
    }

    // MARK: - Setup

    private func installMonitors() {
        let modifierMask: NSEvent.EventTypeMask = [.flagsChanged]
        let keyMask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]

        for mask in [modifierMask, keyMask, mouseMask] {
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.handleEvent(event)
                return event
            }) {
                localMonitors.append(local)
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.handleEvent(event)
            }) {
                globalMonitors.append(global)
            }
        }
    }

    private func observeStoreChanges() {
        // When bindings change, drop any open press state — the binding the
        // user was holding may no longer exist (or its trigger may have
        // changed mid-press, leaving us out of sync). Releases are
        // best-effort: we explicitly stop talking on PTT-family resets so
        // we don't leave the mic open.
        storeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetOpenPresses()
            }
        }
    }

    private func resetOpenPresses() {
        guard !firedBindingIDs.isEmpty else { return }
        // Best-effort: stop voice transmit if we had a hold-style binding
        // open. If the user wasn't actually transmitting, this is a no-op.
        client?.stopTalking()
        firedBindingIDs.removeAll()
    }

    // MARK: - Capture coordination

    /// Pause routing while the Preferences UI is capturing a new shortcut.
    /// Force-releases any hold-style bindings that are currently open and
    /// drops cached input state so events received between `pause()` and
    /// `resume()` don't carry stale "is held" assumptions forward.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        let toRelease = firedBindingIDs
        firedBindingIDs.removeAll()
        activeModifiers = []
        pressedKeys.removeAll()
        pressedMouseButtons.removeAll()
        for id in toRelease {
            if let binding = store.bindings.first(where: { $0.id == id }) {
                handleRelease(binding)
            }
        }
    }

    func resume() {
        isPaused = false
    }

    // MARK: - Event ingestion

    private func handleEvent(_ event: NSEvent) {
        guard !isPaused else { return }
        switch event.type {
        case .flagsChanged:
            activeModifiers = ShortcutModifiers.from(event.modifierFlags)
        case .keyDown:
            // Auto-repeat key-downs flood at the system repeat rate; treat
            // them as a no-op so a held key doesn't repeatedly fire onPress.
            if !event.isARepeat {
                pressedKeys.insert(event.keyCode)
            }
            activeModifiers = ShortcutModifiers.from(event.modifierFlags)
        case .keyUp:
            pressedKeys.remove(event.keyCode)
            activeModifiers = ShortcutModifiers.from(event.modifierFlags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedMouseButtons.insert(event.buttonNumber)
            activeModifiers = ShortcutModifiers.from(event.modifierFlags)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedMouseButtons.remove(event.buttonNumber)
            activeModifiers = ShortcutModifiers.from(event.modifierFlags)
        default:
            return
        }
        evaluateBindings()
    }

    private func evaluateBindings() {
        for binding in store.bindings {
            guard let trigger = binding.trigger else { continue }
            let isFiring = matches(trigger)
            let wasFiring = firedBindingIDs.contains(binding.id)
            if isFiring && !wasFiring {
                firedBindingIDs.insert(binding.id)
                handlePress(binding)
            } else if !isFiring && wasFiring {
                firedBindingIDs.remove(binding.id)
                handleRelease(binding)
            }
        }
    }

    private func matches(_ trigger: ShortcutTrigger) -> Bool {
        switch trigger {
        case let .modifiersOnly(mods):
            // Empty modifier set wouldn't be addressable (always firing); reject.
            return !mods.isEmpty && activeModifiers.isSuperset(of: mods)
        case let .key(mods, keyCode, _):
            return pressedKeys.contains(keyCode)
                && activeModifiers.isSuperset(of: mods)
        case let .mouseButton(mods, button):
            return pressedMouseButtons.contains(button)
                && activeModifiers.isSuperset(of: mods)
        }
    }

    // MARK: - Action handlers

    private func handlePress(_ binding: ShortcutBinding) {
        guard let client else { return }
        switch binding.action {
        case .pushToTalk:
            client.startTalking()
        case .pushToMute:
            Task { await client.setSelfMute(true) }
        case .muteSelfToggle:
            let isMuted = localUserMuted(client: client)
            Task { await client.setSelfMute(!isMuted) }
        case .deafenSelfToggle:
            let isDeaf = localUserDeafened(client: client)
            Task { await client.setSelfDeaf(!isDeaf) }
        case .whisperShout:
            let target = binding.whisperTarget
            Task {
                await client.applyWhisperTarget(target)
                client.startTalking()
            }
        }
    }

    private func handleRelease(_ binding: ShortcutBinding) {
        guard let client else { return }
        switch binding.action {
        case .pushToTalk:
            client.stopTalking()
        case .pushToMute:
            Task { await client.setSelfMute(false) }
        case .muteSelfToggle, .deafenSelfToggle:
            // Toggles ignore release.
            return
        case .whisperShout:
            Task {
                client.stopTalking()
                await client.applyWhisperTarget(nil)
            }
        }
    }

    private func localUserMuted(client: MumbleClient) -> Bool {
        guard let session = client.sessionID else { return false }
        return client.users[session]?.isSelfMuted ?? false
    }

    private func localUserDeafened(client: MumbleClient) -> Bool {
        guard let session = client.sessionID else { return false }
        return client.users[session]?.isSelfDeafened ?? false
    }
}
