import XCTest
@testable import mumble_macos

/// Exercises the regime classification for the PTT release cutoff. All
/// cases are pure-math: synthetic host-time tuples in, `Decision` out.
/// Boundary-exact cases (cutoff at start, cutoff at end) are explicit
/// because the rounding window is what makes them correct in the first
/// place.
final class CaptureCutoffTests: XCTestCase {

    func test_wholeBufferBeforeCutoff_isBeforeCutoff() {
        let d = CaptureCutoff.decide(
            bufferStartHost: 100,
            bufferEndHost: 200,
            cutoffHost: 500,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .beforeCutoff)
    }

    func test_wholeBufferAfterCutoff_isAfterCutoff() {
        let d = CaptureCutoff.decide(
            bufferStartHost: 1_000,
            bufferEndHost: 2_000,
            cutoffHost: 500,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_cutoffExactlyAtBufferStart_isAfterCutoff() {
        // Edge: cutoff == bufferStartHost. No samples to take, so
        // finalize immediately.
        let d = CaptureCutoff.decide(
            bufferStartHost: 1_000,
            bufferEndHost: 2_000,
            cutoffHost: 1_000,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_cutoffExactlyAtBufferEnd_isBeforeCutoff() {
        // Edge: cutoff == bufferEndHost. The whole buffer is pre-cutoff;
        // the *next* tap callback will trigger finalize.
        let d = CaptureCutoff.decide(
            bufferStartHost: 1_000,
            bufferEndHost: 2_000,
            cutoffHost: 2_000,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .beforeCutoff)
    }

    func test_midBuffer30Percent_takes30Samples() {
        let d = CaptureCutoff.decide(
            bufferStartHost: 0,
            bufferEndHost: 100,
            cutoffHost: 30,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .straddle(inputSamplesToTake: 30))
    }

    func test_fractionNearOne_roundsUpToWholeBuffer() {
        // 99.9% through the buffer rounds to taking all 100 samples.
        // That yields a `.straddle(100)` rather than `.beforeCutoff`
        // because we need to finalize after consuming — `.beforeCutoff`
        // would defer the terminator to the next callback that may
        // never arrive.
        let d = CaptureCutoff.decide(
            bufferStartHost: 0,
            bufferEndHost: 1_000,
            cutoffHost: 999,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .straddle(inputSamplesToTake: 100))
    }

    func test_fractionRoundingToZero_collapsesToAfterCutoff() {
        // 0.4% through the buffer (n = round(0.4) = 0). Don't ship a
        // `.straddle(0)` — drain instead. Note: Swift's `.rounded()`
        // default is .toNearestOrAwayFromZero, so the threshold is at
        // fraction < 0.005 for inputFrameLength=100.
        let d = CaptureCutoff.decide(
            bufferStartHost: 0,
            bufferEndHost: 1_000,
            cutoffHost: 4,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_degenerate_zeroDurationBuffer_isAfterCutoff() {
        // Defensive: avoids divide-by-zero on the fraction math.
        let d = CaptureCutoff.decide(
            bufferStartHost: 1_000,
            bufferEndHost: 1_000,
            cutoffHost: 1_000,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_degenerate_zeroFrameLength_isAfterCutoff() {
        let d = CaptureCutoff.decide(
            bufferStartHost: 0,
            bufferEndHost: 1_000,
            cutoffHost: 500,
            inputFrameLength: 0
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    // MARK: - Wall-clock variant
    //
    // Mirrors the host-time cases above. Exercised when the tap's
    // `AVAudioTime.isHostTimeValid` is false. Uses a fixed `base`
    // `ContinuousClock.Instant` plus deterministic offsets — `Instant`
    // arithmetic is exact for these magnitudes.

    func test_wallClock_wholeBufferBeforeCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(100)),
            cutoff: base.advanced(by: .milliseconds(500)),
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .beforeCutoff)
    }

    func test_wallClock_wholeBufferAfterCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base.advanced(by: .milliseconds(1_000)),
            bufferEnd: base.advanced(by: .milliseconds(2_000)),
            cutoff: base.advanced(by: .milliseconds(500)),
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_wallClock_cutoffExactlyAtBufferStart_isAfterCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(100)),
            cutoff: base,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_wallClock_cutoffExactlyAtBufferEnd_isBeforeCutoff() {
        let base = ContinuousClock.now
        let bufferEnd = base.advanced(by: .milliseconds(100))
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: bufferEnd,
            cutoff: bufferEnd,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .beforeCutoff)
    }

    func test_wallClock_midBuffer30Percent_takes30Samples() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(100)),
            cutoff: base.advanced(by: .milliseconds(30)),
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .straddle(inputSamplesToTake: 30))
    }

    func test_wallClock_fractionNearOne_clampsToWholeBuffer() {
        // 99.9% through the buffer rounds to 100 samples; the explicit
        // `n >= inputFrameLength` clamp keeps it at exactly the buffer
        // length (the host-time path's CaptureCutoff.decide doesn't
        // need this clamp because integer mach ticks can't drift past
        // it via rounding the way `Duration`'s atto-second precision
        // sometimes can).
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(1_000)),
            cutoff: base.advanced(by: .milliseconds(999)),
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .straddle(inputSamplesToTake: 100))
    }

    func test_wallClock_fractionRoundingToZero_collapsesToAfterCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(1_000)),
            cutoff: base.advanced(by: .milliseconds(4)),
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_wallClock_degenerate_zeroDurationBuffer_isAfterCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base,
            cutoff: base,
            inputFrameLength: 100
        )
        XCTAssertEqual(d, .afterCutoff)
    }

    func test_wallClock_degenerate_zeroFrameLength_isAfterCutoff() {
        let base = ContinuousClock.now
        let d = CaptureCutoff.decideWallClock(
            bufferStart: base,
            bufferEnd: base.advanced(by: .milliseconds(1_000)),
            cutoff: base.advanced(by: .milliseconds(500)),
            inputFrameLength: 0
        )
        XCTAssertEqual(d, .afterCutoff)
    }
}
