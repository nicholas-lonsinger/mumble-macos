import Foundation

/// Pure decision logic for sample-accurate PTT release. Pulled out of
/// `VoiceController` so the regime classification can be unit-tested
/// without spinning up `AVAudioEngine`.
///
/// Background: `stopTransmit` snapshots a host-time `Mark` at the moment
/// the user released the key. Subsequent input-tap buffers (which the OS
/// is still delivering with audio captured *before* the release — see
/// `mumble-macos/.claude/CLAUDE.md` on the ~100 ms VM/Bluetooth tap
/// cadence) are classified against that mark and either consumed whole,
/// dropped whole, or sliced at the boundary sample.
///
/// All math is in `UInt64` mach absolute ticks. The caller is responsible
/// for converting `AVAudioTime` ↔ host time and for re-running its own
/// `AVAudioConverter` on the truncated input prefix in the straddle case;
/// this type knows nothing about audio formats.
struct CaptureCutoff {
    struct Mark: Equatable, Sendable {
        let hostTime: UInt64
    }

    enum Decision: Equatable {
        /// Whole buffer predates the cutoff — consume normally, no
        /// terminator.
        case beforeCutoff
        /// Whole buffer postdates the cutoff — drain `pendingSamples`,
        /// fire the terminator, no new audio appended. Also returned for
        /// degenerate inputs and for sub-sample fractions that round to
        /// zero, since shipping `.straddle(0)` would just be pointless
        /// work.
        case afterCutoff
        /// Take the first `inputSamplesToTake` samples of the buffer in
        /// *input format units* (the caller slices the raw tap buffer,
        /// runs that prefix through its converter, then drains and fires
        /// the terminator). Never zero — the helper collapses zero into
        /// `.afterCutoff`.
        case straddle(inputSamplesToTake: Int)
    }

    static func decide(
        bufferStartHost: UInt64,
        bufferEndHost: UInt64,
        cutoffHost: UInt64,
        inputFrameLength: Int
    ) -> Decision {
        if inputFrameLength <= 0 || bufferEndHost <= bufferStartHost {
            return .afterCutoff
        }
        if cutoffHost <= bufferStartHost {
            return .afterCutoff
        }
        if cutoffHost >= bufferEndHost {
            return .beforeCutoff
        }
        let span = Double(bufferEndHost - bufferStartHost)
        let into = Double(cutoffHost - bufferStartHost)
        let n = Int((into / span * Double(inputFrameLength)).rounded())
        if n <= 0 {
            return .afterCutoff
        }
        return .straddle(inputSamplesToTake: n)
    }

    /// Wall-clock variant of `decide(...)` used when the tap's
    /// `AVAudioTime.isHostTimeValid` is false (rare — AUv3, virtual
    /// devices). Same regime semantics, just over `ContinuousClock`
    /// timestamps instead of mach ticks. The caller passes the
    /// approximate buffer span — typically `bufferEnd` is when the tap
    /// callback fired and `bufferStart` is that minus the buffer's
    /// duration, since the tap delivers audio captured *before* the
    /// callback fires.
    static func decideWallClock(
        bufferStart: ContinuousClock.Instant,
        bufferEnd: ContinuousClock.Instant,
        cutoff: ContinuousClock.Instant,
        inputFrameLength: Int
    ) -> Decision {
        if inputFrameLength <= 0 || bufferEnd <= bufferStart {
            return .afterCutoff
        }
        if cutoff <= bufferStart {
            return .afterCutoff
        }
        if cutoff >= bufferEnd {
            return .beforeCutoff
        }
        let into = cutoff - bufferStart
        let span = bufferEnd - bufferStart
        let intoSec = Double(into.components.seconds) + Double(into.components.attoseconds) / 1e18
        let spanSec = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        guard spanSec > 0 else { return .afterCutoff }
        let n = Int(((intoSec / spanSec) * Double(inputFrameLength)).rounded())
        if n <= 0 {
            return .afterCutoff
        }
        if n >= inputFrameLength {
            return .straddle(inputSamplesToTake: inputFrameLength)
        }
        return .straddle(inputSamplesToTake: n)
    }
}
