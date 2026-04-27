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
    /// Captured local-mute state at the moment a `pushToMute` binding was
    /// pressed. Restored on release so a Push-to-Mute hold doesn't end up
    /// *unmuting* a user who was already muted via Mute Self.
    private var pushToMutePriorStates: [UUID: Bool] = [:]
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
        // Best-effort: stop voice transmit and clear any active whisper
        // target. Without the whisper reset, `outgoingVoiceTarget` would
        // stay pinned to slot 1 from a prior Whisper press — the next
        // normal PTT would silently transmit as a whisper instead.
        client?.stopTalking()
        Task { [weak self] in
            await self?.client?.applyWhisperTarget(nil)
        }
        firedBindingIDs.removeAll()
        // Drop any captured push-to-mute prior states. The releases we'd
        // normally use to restore them aren't going to fire (the bindings
        // they reference may have changed identity); nothing to restore.
        pushToMutePriorStates.removeAll()
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
            // Snapshot the local mute state at press-time so the release
            // can restore it. Without this, holding Push-to-Mute over a
            // user who's already muted via toggle would unmute them when
            // released.
            let session = client.sessionID
            let priorMute = session.flatMap { client.users[$0]?.isSelfMuted } ?? false
            pushToMutePriorStates[binding.id] = priorMute
            Task { await client.setSelfMute(true) }
        case .muteSelfToggle:
            // Toggle is atomic on the client (read-modify-write inside the
            // main actor) — avoids the rapid-double-tap race.
            Task { await client.toggleSelfMute() }
        case .deafenSelfToggle:
            Task { await client.toggleSelfDeaf() }
        case .whisperShout:
            let target = binding.whisperTarget
            let bindingID = binding.id
            Task { [weak self] in
                await client.applyWhisperTarget(target)
                guard let self, self.firedBindingIDs.contains(bindingID) else {
                    // The user released during our applyWhisperTarget await.
                    // The release's `applyWhisperTarget(nil)` may have run
                    // first and we just stomped it; reset if no other
                    // whisper binding is still holding the slot.
                    if self?.hasActiveWhisperBinding != true {
                        await client.applyWhisperTarget(nil)
                    }
                    return
                }
                client.startTalking()
            }
        }
    }

    private func handleRelease(_ binding: ShortcutBinding) {
        guard let client else { return }
        switch binding.action {
        case .pushToTalk:
            // Don't stop the mic if another transmission-triggering binding
            // (PTT or Whisper) is still held — multi-binding setups would
            // otherwise cut each other off.
            if !hasActiveTransmissionBinding {
                client.stopTalking()
            }
        case .pushToMute:
            // Restore the mute state captured at press-time, defaulting to
            // unmuted if we somehow missed the snapshot.
            let prior = pushToMutePriorStates.removeValue(forKey: binding.id) ?? false
            Task { await client.setSelfMute(prior) }
        case .muteSelfToggle, .deafenSelfToggle:
            // Toggles ignore release.
            return
        case .whisperShout:
            // Snapshot before the Task — the firedBindingIDs read needs to
            // happen synchronously on the main actor, before any await.
            let stopVoice = !hasActiveTransmissionBinding
            let clearTarget = !hasActiveWhisperBinding
            Task {
                if stopVoice { client.stopTalking() }
                if clearTarget {
                    await client.applyWhisperTarget(nil)
                }
            }
        }
    }

    /// True if any other transmission-triggering binding (PTT or Whisper)
    /// is currently held. Read after the released binding has already been
    /// removed from `firedBindingIDs`, so this only sees *other* presses.
    private var hasActiveTransmissionBinding: Bool {
        firedBindingIDs.contains(where: { id in
            guard let action = store.bindings.first(where: { $0.id == id })?.action
            else { return false }
            return action == .pushToTalk || action == .whisperShout
        })
    }

    private var hasActiveWhisperBinding: Bool {
        firedBindingIDs.contains(where: { id in
            store.bindings.first(where: { $0.id == id })?.action == .whisperShout
        })
    }
}
