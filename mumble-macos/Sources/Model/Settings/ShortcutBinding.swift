import AppKit
import Foundation

/// Actions a shortcut can trigger. MVP set: PTT family + Whisper.
enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case pushToTalk
    case pushToMute
    case muteSelfToggle
    case deafenSelfToggle
    case whisperShout

    var displayName: String {
        switch self {
        case .pushToTalk:        return "Push-to-Talk"
        case .pushToMute:        return "Push-to-Mute"
        case .muteSelfToggle:    return "Mute Self"
        case .deafenSelfToggle:  return "Deafen Self"
        case .whisperShout:      return "Whisper/Shout"
        }
    }

    var requiresWhisperTarget: Bool { self == .whisperShout }

    /// Hold-style actions care about both press and release. Toggles only fire on press.
    var isHoldAction: Bool {
        switch self {
        case .pushToTalk, .pushToMute, .whisperShout: return true
        case .muteSelfToggle, .deafenSelfToggle:      return false
        }
    }
}

/// Modifier keys we accept in a shortcut chord.
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let fn       = ShortcutModifiers(rawValue: 1 << 0)
    static let control  = ShortcutModifiers(rawValue: 1 << 1)
    static let shift    = ShortcutModifiers(rawValue: 1 << 2)
    static let option   = ShortcutModifiers(rawValue: 1 << 3)
    static let command  = ShortcutModifiers(rawValue: 1 << 4)
    static let capsLock = ShortcutModifiers(rawValue: 1 << 5)

    /// Project an `NSEvent.ModifierFlags` mask onto our bag.
    static func from(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var out: ShortcutModifiers = []
        if flags.contains(.function) { out.insert(.fn) }
        if flags.contains(.control)  { out.insert(.control) }
        if flags.contains(.shift)    { out.insert(.shift) }
        if flags.contains(.option)   { out.insert(.option) }
        if flags.contains(.command)  { out.insert(.command) }
        if flags.contains(.capsLock) { out.insert(.capsLock) }
        return out
    }

    /// Human-readable in the order the reference Mumble UI uses.
    /// `[.fn, .control]` → "'Fn' 'Control'".
    var displayString: String {
        var parts: [String] = []
        if contains(.fn)       { parts.append("'Fn'") }
        if contains(.control)  { parts.append("'Control'") }
        if contains(.shift)    { parts.append("'Shift'") }
        if contains(.option)   { parts.append("'Option'") }
        if contains(.command)  { parts.append("'Command'") }
        if contains(.capsLock) { parts.append("'CapsLock'") }
        return parts.joined(separator: " ")
    }
}

/// What input fires a binding. Three families supported in MVP.
enum ShortcutTrigger: Codable, Equatable, Hashable, Sendable {
    /// Modifier-only chord. Fires on `.flagsChanged` while the held modifier set is a
    /// non-empty superset of `modifiers`.
    case modifiersOnly(modifiers: ShortcutModifiers)

    /// Key with optional modifiers. Fires on matching `.keyDown`, releases on `.keyUp`.
    /// `displayName` is captured at bind time from `NSEvent.charactersIgnoringModifiers`
    /// (or a hardcoded special-key name) so the UI doesn't have to re-resolve the
    /// keycode against the current keyboard layout each render.
    case key(modifiers: ShortcutModifiers, keyCode: UInt16, displayName: String)

    /// Mouse button with optional modifiers. `buttonNumber` is AppKit-style:
    /// 0 = left, 1 = right, 2+ = "other" (back/forward, etc.).
    case mouseButton(modifiers: ShortcutModifiers, buttonNumber: Int)

    var modifiers: ShortcutModifiers {
        switch self {
        case let .modifiersOnly(m):    return m
        case let .key(m, _, _):        return m
        case let .mouseButton(m, _):   return m
        }
    }

    var displayString: String {
        switch self {
        case let .modifiersOnly(m):
            return m.isEmpty ? "—" : m.displayString
        case let .key(m, _, name):
            let prefix = m.displayString
            return prefix.isEmpty ? name : "\(prefix) \(name)"
        case let .mouseButton(m, button):
            let label = "Mouse \(button + 1)"
            let prefix = m.displayString
            return prefix.isEmpty ? label : "\(prefix) \(label)"
        }
    }

    /// True if no usable input is bound.
    var isEmpty: Bool {
        if case let .modifiersOnly(m) = self { return m.isEmpty }
        return false
    }

    /// Best-effort label for a virtual keycode. Used at *capture* time so we can
    /// stash a stable display name alongside the keycode. Falls back to "Key 0xNN"
    /// when the layout doesn't yield a printable character (e.g., dead keys).
    static func keyDisplayName(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let chars = characters, !chars.isEmpty {
            return chars.uppercased()
        }
        return String(format: "Key 0x%02X", keyCode)
    }

    /// HIToolbox virtual-keycode → human label for keys whose `characters` value
    /// is empty or non-printable. Covers F-keys, arrows, navigation, and the
    /// glyph-less control keys.
    private static let specialKeyNames: [UInt16: String] = [
        0x24: "Return",
        0x30: "Tab",
        0x31: "Space",
        0x33: "Delete",
        0x35: "Escape",
        0x60: "F5",   0x61: "F6",   0x62: "F7",   0x63: "F3",
        0x64: "F8",   0x65: "F9",   0x67: "F11",  0x69: "F13",
        0x6A: "F16",  0x6B: "F14",  0x6D: "F10",  0x6F: "F12",
        0x71: "F15",  0x73: "Home", 0x74: "Page Up",
        0x75: "Forward Delete", 0x76: "F4", 0x77: "End",
        0x78: "F2",   0x79: "Page Down", 0x7A: "F1",
        0x7B: "Left", 0x7C: "Right", 0x7D: "Down", 0x7E: "Up",
    ]
}

/// Whisper-target configuration for a `whisperShout` binding.
struct WhisperTarget: Codable, Equatable, Hashable, Sendable {
    enum ChannelMode: String, Codable, Sendable {
        case current
        case root
        case parent
        case byID
    }

    var channelMode: ChannelMode = .current
    /// Only meaningful when `channelMode == .byID`.
    var channelID: UInt32?
    var includeLinks: Bool = false
    var includeChildren: Bool = false
    var restrictGroup: String = ""

    /// Human-readable summary for the table's "Data" column.
    /// Caller passes the channel-name lookup; this type doesn't depend on `MumbleClient`.
    func summary(channelName: (UInt32) -> String?) -> String {
        switch channelMode {
        case .current: return "Current"
        case .root:    return "Root"
        case .parent:  return "Parent"
        case .byID:
            if let id = channelID, let name = channelName(id), !name.isEmpty { return name }
            return "Channel"
        }
    }
}

/// A single user-configurable shortcut row.
struct ShortcutBinding: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var action: ShortcutAction
    /// `nil` means the row exists but no input has been bound yet.
    var trigger: ShortcutTrigger?
    /// Only meaningful when `action == .whisperShout`.
    var whisperTarget: WhisperTarget?

    init(id: UUID = UUID(),
         action: ShortcutAction,
         trigger: ShortcutTrigger? = nil,
         whisperTarget: WhisperTarget? = nil) {
        self.id = id
        self.action = action
        self.trigger = trigger
        self.whisperTarget = whisperTarget
    }
}
