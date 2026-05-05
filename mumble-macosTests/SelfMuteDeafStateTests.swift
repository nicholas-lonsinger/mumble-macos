import XCTest
@testable import mumble_macos

/// Exercises the snapshot-and-restore rules for self-mute/self-deafen.
/// The four interesting sequences are covered: plain deafen→undeafen,
/// mute→deafen→undeafen, deafen→manual-mute-toggle→undeafen, and
/// mute→deafen→manual-unmute→undeafen.
final class SelfMuteDeafStateTests: XCTestCase {

    // MARK: - Mute alone

    func test_setMuteTrue_fromUnmuted_sendsMuteOnly_clearsSnapshot() {
        var s = SelfMuteDeafState(preDeafenSnapshot: true)
        let d = s.setMute(true, currentMute: false, currentDeaf: false)
        XCTAssertEqual(d, .init(mute: true, deaf: nil))
        XCTAssertNil(s.preDeafenSnapshot)
    }

    func test_setMuteFalse_fromMuted_alsoClearsDeaf() {
        // Even when not deafened, setMute(false) clears deaf optimistically
        // because the server clears it on receipt — keeps the deafen
        // button from lagging the round-trip when the user *was* deafened.
        var s = SelfMuteDeafState()
        let d = s.setMute(false, currentMute: true, currentDeaf: false)
        XCTAssertEqual(d, .init(mute: false, deaf: false))
    }

    func test_setMuteFalse_fromMutedAndDeafened_clearsBoth() {
        var s = SelfMuteDeafState(preDeafenSnapshot: false)
        let d = s.setMute(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(d, .init(mute: false, deaf: false))
        XCTAssertNil(s.preDeafenSnapshot, "manual mute toggle invalidates the snapshot")
    }

    // MARK: - Deafen edge transitions

    func test_setDeafTrue_fromUnmuted_capturesUnmutedSnapshot() {
        var s = SelfMuteDeafState()
        let d = s.setDeaf(true, currentMute: false, currentDeaf: false)
        XCTAssertEqual(d, .init(mute: true, deaf: true))
        XCTAssertEqual(s.preDeafenSnapshot, false)
    }

    func test_setDeafTrue_fromMuted_capturesMutedSnapshot() {
        var s = SelfMuteDeafState()
        let d = s.setDeaf(true, currentMute: true, currentDeaf: false)
        XCTAssertEqual(d, .init(mute: true, deaf: true))
        XCTAssertEqual(s.preDeafenSnapshot, true)
    }

    func test_setDeafTrue_whenAlreadyDeafened_doesNotOverwriteSnapshot() {
        // Re-entry into the deafened state (e.g. server echo, double-fire)
        // must not stomp the original capture.
        var s = SelfMuteDeafState(preDeafenSnapshot: true)
        let d = s.setDeaf(true, currentMute: true, currentDeaf: true)
        XCTAssertEqual(d, .init(mute: true, deaf: true))
        XCTAssertEqual(s.preDeafenSnapshot, true, "snapshot from the original transition is preserved")
    }

    // MARK: - Undeafen restoration

    func test_setDeafFalse_withUnmutedSnapshot_restoresUnmuted() {
        // deafen-from-unmuted → undeafen unmutes.
        var s = SelfMuteDeafState(preDeafenSnapshot: false)
        let d = s.setDeaf(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(d, .init(mute: false, deaf: false))
        XCTAssertNil(s.preDeafenSnapshot)
    }

    func test_setDeafFalse_withMutedSnapshot_keepsMuted() {
        // mute → deafen → undeafen preserves the manual mute. This is
        // the headline bug from the user-reported sequence.
        var s = SelfMuteDeafState(preDeafenSnapshot: true)
        let d = s.setDeaf(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(d, .init(mute: true, deaf: false))
        XCTAssertNil(s.preDeafenSnapshot)
    }

    func test_setDeafFalse_withNoSnapshot_leavesMuteAlone() {
        // No snapshot = we never observed the transition (e.g. server
        // pushed selfDeaf=true on its own). Don't guess; just clear deaf.
        var s = SelfMuteDeafState(preDeafenSnapshot: nil)
        let d = s.setDeaf(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(d, .init(mute: nil, deaf: false))
        XCTAssertNil(s.preDeafenSnapshot)
    }

    // MARK: - Full sequences

    func test_sequence_muteThenDeafenThenUndeafen_remainsMuted() {
        var s = SelfMuteDeafState()

        _ = s.setMute(true, currentMute: false, currentDeaf: false)
        // simulated current state: mute=true, deaf=false

        let afterDeaf = s.setDeaf(true, currentMute: true, currentDeaf: false)
        XCTAssertEqual(afterDeaf, .init(mute: true, deaf: true))
        XCTAssertEqual(s.preDeafenSnapshot, true)

        let afterUndeaf = s.setDeaf(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(afterUndeaf, .init(mute: true, deaf: false))
    }

    func test_sequence_deafenThenUndeafen_fullyClears() {
        var s = SelfMuteDeafState()

        let afterDeaf = s.setDeaf(true, currentMute: false, currentDeaf: false)
        XCTAssertEqual(afterDeaf, .init(mute: true, deaf: true))
        XCTAssertEqual(s.preDeafenSnapshot, false)

        let afterUndeaf = s.setDeaf(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(afterUndeaf, .init(mute: false, deaf: false))
    }

    func test_sequence_deafenThenManualMuteToggle_invalidatesSnapshot() {
        // After deafen, user manually unmutes (via the mic button). The
        // snapshot is now stale; a later "undeafen" shouldn't restore a
        // value the user has already overridden.
        var s = SelfMuteDeafState()

        _ = s.setDeaf(true, currentMute: false, currentDeaf: false)
        XCTAssertEqual(s.preDeafenSnapshot, false)

        // User clicks mic button while in muted+deafened state.
        _ = s.setMute(false, currentMute: true, currentDeaf: true)
        XCTAssertNil(s.preDeafenSnapshot)
    }

    func test_sequence_muteThenDeafenThenManualUnmute_clearsBothNoRestore() {
        var s = SelfMuteDeafState()

        _ = s.setMute(true, currentMute: false, currentDeaf: false)
        _ = s.setDeaf(true, currentMute: true, currentDeaf: false)
        XCTAssertEqual(s.preDeafenSnapshot, true)

        // User explicitly unmutes mid-deafen — overrides the snapshot.
        let afterUnmute = s.setMute(false, currentMute: true, currentDeaf: true)
        XCTAssertEqual(afterUnmute, .init(mute: false, deaf: false))
        XCTAssertNil(s.preDeafenSnapshot)
    }
}
