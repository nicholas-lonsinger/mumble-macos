import Foundation

/// Pure state machine for the self-mute / self-deafen interaction. Pulled
/// out of `MumbleClient` so the transition rules can be unit-tested
/// without a live connection.
///
/// Mumble's invariant is "deaf implies mute" — there is no valid
/// `unmuted + deafened` state. The non-trivial bits are:
/// - **Undeafen restores prior mute.** Snapshotting mute on the
///   `!deaf → deaf` transition lets `mute → deafen → undeafen` keep the
///   user muted, while a plain `deafen → undeafen` clears it.
/// - **Unmute also undeafens.** The server clears `selfDeaf` when it
///   receives `selfMute=false`; applying both flags optimistically keeps
///   the deafen button in step with the mute button instead of waiting
///   for the round-trip echo.
/// - **Manual mute toggles invalidate the snapshot.** The user has set a
///   new baseline; a later undeafen should leave mute alone rather than
///   restore an overridden value.
struct SelfMuteDeafState: Equatable {
    /// Mute value captured the moment the user transitioned into deaf.
    /// Nil means "no snapshot held," in which case undeafen leaves mute
    /// untouched (e.g. if the deafened state arrived from elsewhere).
    var preDeafenSnapshot: Bool?

    /// What the caller should apply locally and send to the server. Nil
    /// in either field means "leave it alone / don't include in the
    /// outgoing UserState."
    struct Decision: Equatable {
        let mute: Bool?
        let deaf: Bool?
    }

    /// Apply a `setSelfMute` action.
    mutating func setMute(_ muted: Bool, currentMute: Bool, currentDeaf: Bool) -> Decision {
        // Explicit mute toggle = new baseline. Drop any deafen-time
        // snapshot so the next undeafen doesn't try to "restore" a
        // value the user has just overridden.
        preDeafenSnapshot = nil
        if muted {
            return Decision(mute: true, deaf: nil)
        }
        // Unmute: clear deaf locally too, since the server will.
        return Decision(mute: false, deaf: false)
    }

    /// Apply a `setSelfDeaf` action.
    mutating func setDeaf(_ deafened: Bool, currentMute: Bool, currentDeaf: Bool) -> Decision {
        if deafened {
            // Capture only on the !deaf → deaf edge so a re-entry doesn't
            // overwrite an existing valid snapshot.
            if !currentDeaf {
                preDeafenSnapshot = currentMute
            }
            return Decision(mute: true, deaf: true)
        }
        // Undeafen: replay snapshot if we have one. Without a snapshot,
        // leave mute alone — we don't know what state to restore to.
        let restored = preDeafenSnapshot
        preDeafenSnapshot = nil
        return Decision(mute: restored, deaf: false)
    }
}
