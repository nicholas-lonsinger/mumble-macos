import AppKit
import XCTest
@testable import mumble_macos

/// Unit tests for the `ShortcutBinding` value layer — focused on Codable
/// round-trips (since storage is JSON in UserDefaults) and the helpers
/// that drive UI labels and dispatcher matching.
final class ShortcutBindingTests: XCTestCase {

    // MARK: - ShortcutModifiers

    func test_modifiers_displayString_matchesReferenceMumbleOrder() {
        let mods: ShortcutModifiers = [.fn, .control]
        XCTAssertEqual(mods.displayString, "'Fn' 'Control'")
    }

    func test_modifiers_displayString_emptyIsEmpty() {
        XCTAssertEqual(ShortcutModifiers([]).displayString, "")
    }

    func test_modifiers_displayString_orderIsStableNotInsertOrder() {
        // [.shift, .fn] should still render Fn first — display order is the
        // documented Mumble UI convention, not the user's insertion order.
        let mods: ShortcutModifiers = [.shift, .fn]
        XCTAssertEqual(mods.displayString, "'Fn' 'Shift'")
    }

    func test_modifiers_from_NSEventFlags_mapsAllSupportedBits() {
        let flags: NSEvent.ModifierFlags = [.function, .control, .shift, .option, .command, .capsLock]
        let mods = ShortcutModifiers.from(flags)
        XCTAssertTrue(mods.contains(.fn))
        XCTAssertTrue(mods.contains(.control))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertTrue(mods.contains(.option))
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.capsLock))
    }

    func test_modifiers_from_NSEventFlags_ignoresIrrelevantBits() {
        // .deviceIndependentFlagsMask, .numericPad, etc. are present in
        // event.modifierFlags but we only project the six bits we care
        // about. Setting numericPad alone yields an empty bag.
        let mods = ShortcutModifiers.from(.numericPad)
        XCTAssertEqual(mods, [])
    }

    // MARK: - ShortcutTrigger Codable round-trip

    func test_trigger_modifiersOnly_roundTripsThroughJSON() throws {
        let trigger = ShortcutTrigger.modifiersOnly(modifiers: [.fn, .control])
        try assertRoundTrips(trigger)
    }

    func test_trigger_key_roundTripsThroughJSON() throws {
        let trigger = ShortcutTrigger.key(modifiers: [.shift], keyCode: 0x11, displayName: "T")
        try assertRoundTrips(trigger)
    }

    func test_trigger_mouseButton_roundTripsThroughJSON() throws {
        let trigger = ShortcutTrigger.mouseButton(modifiers: [], buttonNumber: 3)
        try assertRoundTrips(trigger)
    }

    private func assertRoundTrips(_ trigger: ShortcutTrigger,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(ShortcutTrigger.self, from: data)
        XCTAssertEqual(decoded, trigger, file: file, line: line)
    }

    // MARK: - ShortcutTrigger.displayString

    func test_trigger_displayString_modifiersOnly() {
        XCTAssertEqual(
            ShortcutTrigger.modifiersOnly(modifiers: [.fn, .control]).displayString,
            "'Fn' 'Control'"
        )
    }

    func test_trigger_displayString_modifiersOnly_emptyShowsDash() {
        // An empty modifier set in `.modifiersOnly` is unaddressable but
        // shouldn't crash the UI; it renders as a placeholder dash.
        XCTAssertEqual(
            ShortcutTrigger.modifiersOnly(modifiers: []).displayString,
            "—"
        )
    }

    func test_trigger_displayString_keyWithModifiers() {
        XCTAssertEqual(
            ShortcutTrigger.key(modifiers: [.shift], keyCode: 0x11, displayName: "T").displayString,
            "'Shift' T"
        )
    }

    func test_trigger_displayString_keyWithoutModifiers() {
        XCTAssertEqual(
            ShortcutTrigger.key(modifiers: [], keyCode: 0x69, displayName: "F13").displayString,
            "F13"
        )
    }

    func test_trigger_displayString_mouseButton1IndexedForUser() {
        // Mumble convention: Mouse 1 = left, Mouse 2 = right, Mouse 3 = middle.
        // Our internal `buttonNumber` is AppKit-style 0-indexed; display adds 1.
        XCTAssertEqual(
            ShortcutTrigger.mouseButton(modifiers: [], buttonNumber: 0).displayString,
            "Mouse 1"
        )
        XCTAssertEqual(
            ShortcutTrigger.mouseButton(modifiers: [.control], buttonNumber: 3).displayString,
            "'Control' Mouse 4"
        )
    }

    // MARK: - ShortcutTrigger.isEmpty

    func test_trigger_isEmpty_modifiersOnlyEmpty() {
        XCTAssertTrue(ShortcutTrigger.modifiersOnly(modifiers: []).isEmpty)
    }

    func test_trigger_isEmpty_modifiersOnlyNonEmpty() {
        XCTAssertFalse(ShortcutTrigger.modifiersOnly(modifiers: [.fn]).isEmpty)
    }

    func test_trigger_isEmpty_keyAndMouseAreNeverEmpty() {
        XCTAssertFalse(ShortcutTrigger.key(modifiers: [], keyCode: 0, displayName: "A").isEmpty)
        XCTAssertFalse(ShortcutTrigger.mouseButton(modifiers: [], buttonNumber: 0).isEmpty)
    }

    // MARK: - keyDisplayName

    func test_keyDisplayName_specialKeyTakesPrecedenceOverChars() {
        // 0x35 is Escape; even if `characters` is non-empty, the special
        // table wins so the label stays "Escape".
        XCTAssertEqual(
            ShortcutTrigger.keyDisplayName(forKeyCode: 0x35, characters: "x"),
            "Escape"
        )
    }

    func test_keyDisplayName_fallsBackToCharsThenHex() {
        XCTAssertEqual(
            ShortcutTrigger.keyDisplayName(forKeyCode: 0x11, characters: "t"),
            "T"
        )
        // No characters and not in the special-key table → hex fallback.
        XCTAssertEqual(
            ShortcutTrigger.keyDisplayName(forKeyCode: 0xFE, characters: nil),
            "Key 0xFE"
        )
    }

    // MARK: - WhisperTarget summary

    func test_whisperTarget_summary_specialModes() {
        XCTAssertEqual(
            WhisperTarget(channelMode: .current).summary(channelName: { _ in nil }),
            "Current"
        )
        XCTAssertEqual(
            WhisperTarget(channelMode: .root).summary(channelName: { _ in nil }),
            "Root"
        )
        XCTAssertEqual(
            WhisperTarget(channelMode: .parent).summary(channelName: { _ in nil }),
            "Parent"
        )
    }

    func test_whisperTarget_summary_byID_resolvesViaLookup() {
        let target = WhisperTarget(channelMode: .byID, channelID: 42)
        XCTAssertEqual(
            target.summary(channelName: { id in id == 42 ? "Lobby" : nil }),
            "Lobby"
        )
    }

    func test_whisperTarget_summary_byID_fallsBackWhenNameMissing() {
        let target = WhisperTarget(channelMode: .byID, channelID: 99)
        XCTAssertEqual(
            target.summary(channelName: { _ in nil }),
            "Channel"
        )
    }

    // MARK: - ShortcutBinding round-trip

    func test_binding_roundTripsThroughJSON_withWhisperTarget() throws {
        let original = ShortcutBinding(
            action: .whisperShout,
            trigger: .modifiersOnly(modifiers: [.fn, .control]),
            whisperTarget: WhisperTarget(
                channelMode: .byID,
                channelID: 7,
                includeLinks: true,
                includeChildren: true,
                restrictGroup: "admin"
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_binding_roundTripsThroughJSON_withNilTrigger() throws {
        // A freshly-added row before the user binds a chord — trigger == nil
        // must survive encode/decode so the row remains "unbound" instead
        // of being dropped or silently filled in.
        let original = ShortcutBinding(action: .pushToMute, trigger: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ShortcutAction action attributes

    func test_action_isHoldAction() {
        XCTAssertTrue(ShortcutAction.pushToTalk.isHoldAction)
        XCTAssertTrue(ShortcutAction.pushToMute.isHoldAction)
        XCTAssertTrue(ShortcutAction.whisperShout.isHoldAction)
        XCTAssertFalse(ShortcutAction.muteSelfToggle.isHoldAction)
        XCTAssertFalse(ShortcutAction.deafenSelfToggle.isHoldAction)
    }

    func test_action_requiresWhisperTarget_onlyWhisperShout() {
        for action in ShortcutAction.allCases {
            XCTAssertEqual(action.requiresWhisperTarget, action == .whisperShout, "\(action)")
        }
    }
}
