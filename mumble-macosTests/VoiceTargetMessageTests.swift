import XCTest
@testable import mumble_macos

/// Encoder tests for `VoiceTargetMessage` — the protobuf wire format for
/// Mumble.proto's `VoiceTarget` (control message type 22). We assert
/// against golden byte sequences derived from the field numbers + wire
/// types in `mumble/src/Mumble.proto:464-482`. Drift would silently
/// break Whisper/Shout because the server wouldn't recognise the slot.
final class VoiceTargetMessageTests: XCTestCase {

    func test_encodesIDOnly_whenNoTargets() {
        let msg = VoiceTargetMessage(id: 1)
        let payload = msg.encodePayload()
        // Field 1 (id, varint): tag = (1 << 3) | 0 = 0x08, value = 1.
        XCTAssertEqual([UInt8](payload), [0x08, 0x01])
    }

    func test_encodesChannelTarget_withChannelID() {
        let msg = VoiceTargetMessage(
            id: 1,
            targets: [.init(channelID: 42)]
        )
        let payload = [UInt8](msg.encodePayload())
        // Header: id field (tag 0x08, value 1) → [0x08, 0x01]
        // Followed by Target submessage: tag = (2 << 3) | 2 = 0x12,
        // length = 2, body = [tag for channel_id (2,varint)=0x10, 0x2A].
        XCTAssertEqual(payload, [0x08, 0x01, 0x12, 0x02, 0x10, 0x2A])
    }

    func test_omitsAbsentOptionalFields() {
        // Empty target submessage has no optional fields set; group/links/
        // children should NOT be encoded when nil. Encoded length should
        // be just `[id-tag, id-value, target-tag, length=0]`.
        let msg = VoiceTargetMessage(id: 1, targets: [.init()])
        let payload = [UInt8](msg.encodePayload())
        XCTAssertEqual(payload, [0x08, 0x01, 0x12, 0x00])
    }

    func test_omitsEmptyGroupString() {
        // Empty `group` is treated as "no group" and skipped.
        let msg = VoiceTargetMessage(id: 1, targets: [.init(channelID: 5, group: "")])
        let payload = [UInt8](msg.encodePayload())
        // Inner: only channel_id (tag 0x10, value 5).
        XCTAssertEqual(payload, [0x08, 0x01, 0x12, 0x02, 0x10, 0x05])
    }

    func test_encodesGroupString_whenSet() {
        let msg = VoiceTargetMessage(id: 2, targets: [.init(group: "ops")])
        let payload = [UInt8](msg.encodePayload())
        // Header: [0x08, 0x02]
        // Inner: group field tag (3,length-delimited)=0x1A, length=3, "ops".
        // Outer target tag = 0x12, target body length = 5 (1 + 1 + 3).
        XCTAssertEqual(
            payload,
            [0x08, 0x02, 0x12, 0x05, 0x1A, 0x03, UInt8(ascii: "o"), UInt8(ascii: "p"), UInt8(ascii: "s")]
        )
    }

    func test_encodesLinksAndChildrenFlags() {
        let msg = VoiceTargetMessage(
            id: 3,
            targets: [.init(channelID: 7, includeLinks: true, includeChildren: true)]
        )
        let payload = [UInt8](msg.encodePayload())
        // Header: [0x08, 0x03]
        // Inner fields:
        //   channel_id (tag 0x10) = 7   → [0x10, 0x07]
        //   links     (tag 0x20) = 1   → [0x20, 0x01]
        //   children  (tag 0x28) = 1   → [0x28, 0x01]
        // body length = 6, target tag = 0x12.
        XCTAssertEqual(
            payload,
            [0x08, 0x03, 0x12, 0x06, 0x10, 0x07, 0x20, 0x01, 0x28, 0x01]
        )
    }

    func test_encodesMultipleSessions_asRepeatedField() {
        let msg = VoiceTargetMessage(
            id: 1,
            targets: [.init(sessions: [10, 20])]
        )
        let payload = [UInt8](msg.encodePayload())
        // Header: [0x08, 0x01]
        // Inner: session repeated (tag 1 varint = 0x08):
        //   [0x08, 0x0A, 0x08, 0x14]
        // target body length = 4, tag 0x12.
        XCTAssertEqual(
            payload,
            [0x08, 0x01, 0x12, 0x04, 0x08, 0x0A, 0x08, 0x14]
        )
    }

    func test_messageType_isVoiceTarget() {
        // Defends against accidental edits to the typed-message map —
        // server would silently ignore us if we used the wrong type id.
        XCTAssertEqual(VoiceTargetMessage.messageType, .voiceTarget)
    }
}
