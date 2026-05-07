@preconcurrency import AVFoundation
import Foundation
import OSLog

enum VoiceControllerError: Error, Sendable, LocalizedError {
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineStartFailed(let reason):
            return "Audio engine failed to start: \(reason)"
        }
    }
}

/// Callback invoked for each finished Opus frame captured from the mic.
/// `frameNumber` is the Mumble sequence (monotonically increasing over the
/// life of the current PTT burst). `isTerminator` is true on the last frame
/// of a burst so the receiver can finalize playback state. `target` is the
/// `MumbleUDP.Audio.target` to attach — captured once when the burst started
/// rather than read at send time, so a target change late in a burst (e.g.
/// the user releases their Whisper key while the send queue still has
/// packets pacing out) doesn't mis-route the tail of the burst onto a
/// different channel.
typealias OpusFrameHandler = @Sendable (Data, UInt64, Bool, UInt32) -> Void

/// Single-process voice engine: captures mic, encodes with Opus, plays back
/// remote streams. Lives outside the MumbleClient actor so the audio tap
/// can stay on the real-time thread without hopping onto the main actor.
final class VoiceController: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "voice")

    /// Wall-clock floor for terminating a burst when no further input-tap
    /// callback arrives after `stopTransmit`. The sample-accurate cutoff
    /// path runs on the *next* tap callback after stop; this fires only
    /// in the degenerate case where the engine stalls or the device
    /// disconnects mid-burst. 500 ms is ~5x the worst observed tap
    /// cadence (~100 ms in VM/Bluetooth per CLAUDE.md).
    private static let cutoffFallbackInterval: Duration = .milliseconds(500)

    private let engine = AVAudioEngine()
    private let playersMixer = AVAudioMixerNode()
    private let lock = NSLock()

    private var engineRunning = false
    private var inputFormat: AVAudioFormat?
    private var inputConverter: AVAudioConverter?

    // Capture / encode state
    private var encoder: OpusEncoder?
    private var pendingSamples: [Float] = []
    private var sendSequence: UInt64 = 0
    private var isTransmitting = false
    /// Live `MumbleUDP.Audio.target`. Mutated from main via
    /// `setVoiceTarget(_:)` whenever the user activates / releases a
    /// Whisper or Shout shortcut; read by the AU thread when starting
    /// a burst.
    private var voiceTarget: UInt32 = 0
    /// Snapshot of `voiceTarget` taken when the current PTT burst
    /// began. All packets in the burst (including any that drain
    /// after the user has already released) carry this value, so the
    /// tail of a Whisper burst can't leak out as normal-channel talk
    /// just because `voiceTarget` was reset before the send queue
    /// finished pacing.
    private var burstTarget: UInt32 = 0

    /// Host-time mark snapshotted when `stopTransmit` is called, used to
    /// truncate the next tap callback at the exact sample of release.
    /// Non-nil while the burst is finalizing; the tap callback path and
    /// the fallback Task both check-then-clear under the lock so whichever
    /// runs first wins and the loser no-ops.
    private var cutoffMark: CaptureCutoff.Mark?
    /// Wall-clock pair for `cutoffMark`, used only on the
    /// `AVAudioTime.isHostTimeValid == false` fallback (rare — AUv3,
    /// virtual devices). Cleared together with `cutoffMark`.
    private var cutoffWallClock: ContinuousClock.Instant?
    /// Safety-net deferred finalize. Fires `cutoffFallbackInterval` after
    /// `stopTransmit` if the next tap callback hasn't already drained the
    /// burst. The Task captures the `Mark` it was scheduled for and
    /// `finalizeAfterCutoff` only drains when the live `cutoffMark`
    /// still matches — defends against a "ghost" wakeup terminating a
    /// later burst when its cancellation propagated too late.
    private var cutoffFallbackTask: Task<Void, Never>?

    // Reusable PCM buffers. Eliminates the per-tap-callback heap
    // allocations Apple's tap-block guidance specifically warns about.
    // All three slots are accessed only from `handleCaptureBuffer` and
    // its callees (always under `lock`), and live for the lifetime of
    // the controller — no stop() cleanup, since the `ensureXxx` helpers
    // re-allocate when the format or capacity demands more, which
    // already covers a `stop()` → `start()` cycle that lands on a
    // different mic. Persisting them avoids a benign data race that a
    // lock-held nil-out would create with the tap thread.
    private var reuseInputPrefix: AVAudioPCMBuffer?
    private var reuseConvertedOutput: AVAudioPCMBuffer?
    private var reuseEncodeFrame: AVAudioPCMBuffer?

    // Per-speaker playback state
    private var speakers: [UInt32: Speaker] = [:]

    var onOpusFrame: OpusFrameHandler?

    init() {
        engine.attach(playersMixer)
        engine.connect(playersMixer, to: engine.mainMixerNode, format: MumbleAudioParameters.pcmFormat)
    }

    /// Boot the audio engine and install the capture tap. Safe to call
    /// multiple times — idempotent.
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if engineRunning { return }

        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        inputFormat = hardwareFormat

        if hardwareFormat.sampleRate != MumbleAudioParameters.sampleRate
            || hardwareFormat.channelCount != MumbleAudioParameters.channelCount {
            inputConverter = AVAudioConverter(from: hardwareFormat, to: MumbleAudioParameters.pcmFormat)
        } else {
            inputConverter = nil
        }

        input.installTap(onBus: 0,
                         bufferSize: 1_024,
                         format: hardwareFormat) { [weak self] buffer, time in
            self?.handleCaptureBuffer(buffer, at: time)
        }

        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
            Self.log.info("Audio engine started — hw \(hardwareFormat.sampleRate, privacy: .public) Hz / \(hardwareFormat.channelCount, privacy: .public) ch")
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceControllerError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        if !engineRunning {
            lock.unlock()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        speakers.values.forEach { $0.player.stop() }
        speakers.removeAll()
        isTransmitting = false
        // Hold the underlying capacity across stop/start cycles so the
        // next burst's first append doesn't have to grow the array — no
        // allocation on the tap thread. (Same rationale on the
        // `removeAll(keepingCapacity: true)` calls in `startTransmit`
        // and `drainBurstLocked`.)
        pendingSamples.removeAll(keepingCapacity: true)
        sendSequence = 0
        encoder = nil
        // Drop any pending cutoff so the fallback Task doesn't fire a
        // terminator after the engine is gone.
        cutoffMark = nil
        cutoffWallClock = nil
        taskToCancel = cutoffFallbackTask
        cutoffFallbackTask = nil
        Self.log.info("Audio engine stopped")
        lock.unlock()
        taskToCancel?.cancel()
    }

    // MARK: - Whisper / target

    /// Update the live `MumbleUDP.Audio.target` that the next PTT
    /// burst will snapshot. Safe to call from main while audio is
    /// flowing on the AU thread — protected by the same lock.
    func setVoiceTarget(_ target: UInt32) {
        lock.lock()
        voiceTarget = target
        lock.unlock()
    }

    // MARK: - Transmit (PTT)

    func startTransmit() {
        var framesToYield: [(Data, UInt64, Bool)] = []
        // The drain frames (if any) carry the *previous* burst's target
        // — they were captured under that burst's `burstTarget` before
        // we overwrite the slot with `voiceTarget` for the new burst.
        // Keeping a separate variable for the drain target prevents a
        // Whisper-A → release → PTT-B sequence from shipping A's tail
        // under B's target. (The old yields-under-the-lock code didn't
        // hit this because the yields happened before `burstTarget`
        // was reassigned; moving yields out of the lock — which we did
        // to keep the straddle path's frame ordering correct — broke
        // the ordering this hidden invariant relied on.)
        var drainTarget: UInt32 = 0
        var taskToCancel: Task<Void, Never>?
        var newBurstTarget: UInt32 = 0
        var handler: OpusFrameHandler?
        var startedBurst = false

        lock.lock()
        defer {
            lock.unlock()
            yieldFrames(framesToYield, target: drainTarget, handler: handler)
            taskToCancel?.cancel()
            if startedBurst {
                Self.log.info("PTT transmit start (target=\(newBurstTarget, privacy: .public))")
            }
        }

        // Re-press during the cutoff window: flush the previous burst's
        // trailing samples + terminator inline before opening a fresh
        // burst. Otherwise we'd inherit the previous burst's encoder
        // state and `burstTarget`, so a Whisper-A → release → Whisper-B
        // sequence could ship the start of B's audio under A's target.
        if cutoffMark != nil {
            cutoffMark = nil
            cutoffWallClock = nil
            drainTarget = burstTarget
            framesToYield = drainBurstLocked()
        }
        taskToCancel = cutoffFallbackTask
        cutoffFallbackTask = nil
        handler = onOpusFrame

        guard engineRunning else { return }
        if isTransmitting { return }

        do {
            encoder = try OpusEncoder()
        } catch {
            Self.log.error("Opus encoder init failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        pendingSamples.removeAll(keepingCapacity: true)
        sendSequence = 0
        burstTarget = voiceTarget
        isTransmitting = true
        newBurstTarget = burstTarget
        startedBurst = true
    }

    func stopTransmit() {
        lock.lock()
        // Idempotency: not transmitting at all, or a cutoff is already
        // pending → no-op. Defends against rapid release/release.
        if !isTransmitting || cutoffMark != nil {
            lock.unlock()
            return
        }
        // Snapshot host time at release. The next tap callback compares
        // each subsequent buffer's `AVAudioTime.hostTime` against this
        // mark and truncates the boundary buffer at the cutoff sample.
        // Wall-clock is the fallback for `!isHostTimeValid` taps.
        let mark = CaptureCutoff.Mark(hostTime: mach_absolute_time())
        cutoffMark = mark
        cutoffWallClock = ContinuousClock.now
        // Schedule the safety-net fallback under the lock — same race
        // rationale as the prior linger-task assignment: a concurrent
        // `startTransmit` could otherwise observe a stale
        // `cutoffFallbackTask` value, drain, and clear the slot, leaving
        // our pending assignment to land afterward as a "ghost" task.
        // The Task captures `mark` so `finalizeAfterCutoff` can verify
        // the cutoff hasn't been replaced by a later burst's mark
        // (cancellation can propagate after the timer has already
        // fired).
        cutoffFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cutoffFallbackInterval)
            if Task.isCancelled { return }
            self?.finalizeAfterCutoff(expecting: mark)
        }
        lock.unlock()
    }

    /// Safety-net finalize. Runs `cutoffFallbackInterval` after
    /// `stopTransmit` if the boundary tap callback hasn't already
    /// finalized the burst. `expecting` is the mark this task was
    /// scheduled for; if `cutoffMark` has been replaced (`startTransmit`
    /// → `stopTransmit` cycled while we slept), we no-op.
    private func finalizeAfterCutoff(expecting mark: CaptureCutoff.Mark) {
        var frames: [(Data, UInt64, Bool)] = []
        var target: UInt32 = 0
        var handler: OpusFrameHandler?

        lock.lock()
        defer {
            lock.unlock()
            yieldFrames(frames, target: target, handler: handler)
        }
        guard cutoffMark == mark, isTransmitting else { return }
        cutoffMark = nil
        cutoffWallClock = nil
        cutoffFallbackTask = nil
        frames = drainBurstLocked()
        target = burstTarget
        handler = onOpusFrame
    }

    /// Caller MUST hold the lock. Pads any partial trailing samples with
    /// silence to a full 20 ms frame and encodes one final packet (so the
    /// last <20 ms of speech isn't dropped on the boundary), appends that
    /// trailing frame and the empty-payload terminator to the returned
    /// list, and resets transmit state. Idempotent — returns an empty
    /// list when not transmitting.
    ///
    /// Returns rather than yielding so callers (which may also have
    /// complete-frame yields built up before calling this) can yield the
    /// unified, in-order list outside the lock. Yielding under the lock
    /// would re-order the terminator ahead of complete frames produced
    /// earlier in the same callback — broken on the wire.
    ///
    /// Reuses the same `reuseEncodeFrame` slot the per-frame drain loop
    /// uses. `encoder.encode` is synchronous and returns a fresh `Data`,
    /// so overwriting the buffer's contents after the call is safe even
    /// when both paths run inside the same tap callback (handleCapture-
    /// Buffer's loop, then drainBurstLocked here). All callers of this
    /// helper hold `lock`, so the shared-slot access is serialized.
    private func drainBurstLocked() -> [(Data, UInt64, Bool)] {
        guard isTransmitting else { return [] }
        var out: [(Data, UInt64, Bool)] = []
        let target = burstTarget
        let framesPerPacket = Int(MumbleAudioParameters.framesPerPacket)

        if !pendingSamples.isEmpty,
           let encoder,
           let pcm = ensureEncodeFrameLocked() {
            pcm.frameLength = AVAudioFrameCount(framesPerPacket)
            if let dst = pcm.floatChannelData?[0] {
                let copyCount = min(pendingSamples.count, framesPerPacket)
                pendingSamples.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: copyCount)
                }
                if copyCount < framesPerPacket {
                    // Pad with silence so libopus encodes a complete frame.
                    (dst + copyCount).update(repeating: 0,
                                             count: framesPerPacket - copyCount)
                }
            }
            do {
                let opus = try encoder.encode(pcm)
                if !opus.isEmpty {
                    let seq = sendSequence
                    sendSequence += MumbleAudioParameters.frameNumberStep
                    out.append((opus, seq, false))
                }
            } catch {
                Self.log.error("Opus encode (final pad) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let terminatorSeq = sendSequence
        Self.log.info("PTT transmit stop (frameNumber=\(terminatorSeq, privacy: .public) target=\(target, privacy: .public))")
        // Empty-payload terminator so the receiver finalizes playback.
        out.append((Data(), terminatorSeq, true))

        isTransmitting = false
        encoder = nil
        pendingSamples.removeAll(keepingCapacity: true)
        return out
    }

    /// Caller must NOT hold the lock. `target` should be captured from
    /// `burstTarget` while the lock was held (right before unlock).
    private func yieldFrames(_ frames: [(Data, UInt64, Bool)],
                             target: UInt32,
                             handler: OpusFrameHandler?) {
        guard let handler else { return }
        for (opus, seq, isTerminator) in frames {
            handler(opus, seq, isTerminator, target)
        }
    }

    // MARK: - Receive

    /// Feed a remote Opus frame into the player for the given session.
    func ingestRemoteAudio(session: UInt32, opus: Data, frameNumber: UInt64, isTerminator: Bool) {
        lock.lock()
        let speaker: Speaker
        if let existing = speakers[session] {
            speaker = existing
        } else {
            do {
                speaker = try Speaker(decoder: OpusDecoder(),
                                      player: AVAudioPlayerNode(),
                                      format: MumbleAudioParameters.pcmFormat)
                engine.attach(speaker.player)
                engine.connect(speaker.player, to: playersMixer, format: MumbleAudioParameters.pcmFormat)
                speaker.player.play()
                speakers[session] = speaker
                Self.log.info("Opened speaker player for session \(session, privacy: .public)")
            } catch {
                lock.unlock()
                Self.log.error("Could not open speaker for session \(session, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        lock.unlock()

        if opus.isEmpty {
            if isTerminator {
                Self.log.debug("Remote session \(session, privacy: .public) ended burst at frame \(frameNumber, privacy: .public)")
            }
            return
        }
        do {
            let pcm = try speaker.decoder.decode(opus)
            speaker.player.scheduleBuffer(pcm, completionHandler: nil)
        } catch {
            Self.log.error("Opus decode failed for session \(session, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeSpeaker(session: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard let speaker = speakers.removeValue(forKey: session) else { return }
        speaker.player.stop()
        engine.disconnectNodeOutput(speaker.player)
        engine.detach(speaker.player)
    }

    // MARK: - Capture tap

    private func handleCaptureBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // Snapshot wall-clock at the very top so the `!isHostTimeValid`
        // fallback computes against the actual tap-fire instant rather
        // than whenever we get around to taking the lock.
        let callbackStart = ContinuousClock.now

        guard let inputFormat else { return }
        let inputFrameLength = Int(buffer.frameLength)
        let bufferDurationSec = Double(inputFrameLength) / inputFormat.sampleRate

        var framesToSend: [(Data, UInt64, Bool)] = []
        var fallbackTaskToCancel: Task<Void, Never>?
        var burstTargetSnapshot: UInt32 = 0
        var handler: OpusFrameHandler?

        lock.lock()
        defer {
            lock.unlock()
            yieldFrames(framesToSend, target: burstTargetSnapshot, handler: handler)
            fallbackTaskToCancel?.cancel()
        }
        guard isTransmitting, let encoder else { return }

        let regime: CaptureCutoff.Decision
        if let mark = cutoffMark {
            if time.isHostTimeValid {
                let bufferStartHost = time.hostTime
                let bufferEndHost = bufferStartHost + AVAudioTime.hostTime(forSeconds: bufferDurationSec)
                regime = CaptureCutoff.decide(
                    bufferStartHost: bufferStartHost,
                    bufferEndHost: bufferEndHost,
                    cutoffHost: mark.hostTime,
                    inputFrameLength: inputFrameLength
                )
            } else if let wall = cutoffWallClock {
                // Wall-clock fallback: approximate the buffer's span as
                // ending at the callback-fire instant and starting one
                // duration earlier. The audio was captured before
                // delivery, so `callbackStart` is the latest plausible
                // edge.
                regime = CaptureCutoff.decideWallClock(
                    bufferStart: callbackStart.advanced(by: .seconds(-bufferDurationSec)),
                    bufferEnd: callbackStart,
                    cutoff: wall,
                    inputFrameLength: inputFrameLength
                )
            } else {
                // Defensive: cutoffMark set but cutoffWallClock missing —
                // shouldn't happen, but treat as already-past-cutoff so
                // we drain rather than spin.
                regime = .afterCutoff
            }
        } else {
            regime = .beforeCutoff
        }

        let inputSamplesToConsume: Int
        let willFinalize: Bool
        switch regime {
        case .beforeCutoff:
            inputSamplesToConsume = inputFrameLength
            willFinalize = false
        case .afterCutoff:
            inputSamplesToConsume = 0
            // `.afterCutoff` is only ever returned when `cutoffMark` is
            // non-nil (the no-cutoff path returns `.beforeCutoff` above),
            // so we always finalize here.
            willFinalize = true
        case .straddle(let n):
            inputSamplesToConsume = n
            willFinalize = true
        }

        if inputSamplesToConsume > 0,
           let channelData = buffer.floatChannelData?[0],
           let convertedOut = convertedBufferLocked(
               from: channelData,
               inputSampleCount: inputSamplesToConsume,
               inputFormat: inputFormat
           ),
           let convertedDst = convertedOut.floatChannelData?[0] {
            let frameCount = Int(convertedOut.frameLength)
            pendingSamples.reserveCapacity(pendingSamples.count + frameCount)
            pendingSamples.append(contentsOf: UnsafeBufferPointer(start: convertedDst, count: frameCount))

            // Drain complete 20 ms frames out of `pendingSamples`,
            // reusing the cached encode buffer to avoid a per-frame
            // alloc. Apple's tap-block guidance specifically calls out
            // "no allocations on the tap thread"; the pool addresses
            // that. Encode all complete frames inside one
            // `withUnsafeBufferPointer` block, then do a single
            // `removeFirst` at the end — `removeFirst(k)` on `[Float]`
            // is O(remaining), so a per-frame call would be O(N²) in
            // the buffer size. One trailing call is O(N).
            let framesPerPacket = Int(MumbleAudioParameters.framesPerPacket)
            let framesToProcess = pendingSamples.count / framesPerPacket
            if framesToProcess > 0, let encodeFrame = ensureEncodeFrameLocked() {
                pendingSamples.withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    encodeFrame.frameLength = AVAudioFrameCount(framesPerPacket)
                    for i in 0..<framesToProcess {
                        let offset = i * framesPerPacket
                        if let dst = encodeFrame.floatChannelData?[0] {
                            dst.update(from: base + offset, count: framesPerPacket)
                        }
                        do {
                            let opus = try encoder.encode(encodeFrame)
                            let seq = sendSequence
                            sendSequence += MumbleAudioParameters.frameNumberStep
                            if !opus.isEmpty {
                                framesToSend.append((opus, seq, false))
                            }
                        } catch {
                            Self.log.error("Opus encode failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
                pendingSamples.removeFirst(framesToProcess * framesPerPacket)
            }
        }

        if willFinalize {
            cutoffMark = nil
            cutoffWallClock = nil
            fallbackTaskToCancel = cutoffFallbackTask
            cutoffFallbackTask = nil
            framesToSend += drainBurstLocked()
        }

        burstTargetSnapshot = burstTarget
        handler = onOpusFrame
    }

    /// Caller MUST hold the lock. Builds an input-format slice of the
    /// first `n` samples (channel 0 only — matches the existing
    /// single-channel assumption), runs it through the existing
    /// converter, returns the converted buffer. Pass-through fast path
    /// when input already matches `MumbleAudioParameters.pcmFormat`.
    /// Returns nil only on allocation failure.
    private func convertedBufferLocked(from channelData: UnsafeMutablePointer<Float>,
                                       inputSampleCount n: Int,
                                       inputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let isPassThrough = inputConverter == nil
            && inputFormat.sampleRate == MumbleAudioParameters.sampleRate
            && inputFormat.channelCount == MumbleAudioParameters.channelCount
        if isPassThrough {
            guard let pcm = ensureConvertedOutputLocked(capacity: AVAudioFrameCount(n)) else {
                return nil
            }
            pcm.frameLength = AVAudioFrameCount(n)
            if let dst = pcm.floatChannelData?[0] {
                dst.update(from: channelData, count: n)
            }
            return pcm
        }
        guard let converter = inputConverter,
              let inBuf = ensureInputPrefixLocked(format: inputFormat,
                                                  capacity: AVAudioFrameCount(n)) else {
            return nil
        }
        inBuf.frameLength = AVAudioFrameCount(n)
        if let dst = inBuf.floatChannelData?[0] {
            dst.update(from: channelData, count: n)
        }
        // Scale output capacity by the sample-rate ratio — otherwise
        // upsampling (e.g. 16 kHz Bluetooth mic → 48 kHz) truncates each
        // tap callback and audio comes out broken/muffled on the wire.
        let ratio = MumbleAudioParameters.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Int((Double(n) * ratio).rounded(.up)) + 32)
        guard let out = ensureConvertedOutputLocked(capacity: outCapacity) else {
            return nil
        }
        // AVAudioConverter calls its input block synchronously, but Swift 6
        // strict concurrency can't see that — capturing a mutable `var`
        // here trips a Sendable diagnostic. Box the once-flag in a tiny
        // reference type to keep the closure capture-list happy.
        let once = ConvertOnce()
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if once.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { return nil }
        return out
    }

    /// Caller MUST hold the lock. Returns the cached input-prefix buffer
    /// if its format matches and capacity suffices; otherwise allocates
    /// a fresh one. Format equality uses `isEqual` on `AVAudioFormat`,
    /// which compares the channel-layout fields correctly.
    private func ensureInputPrefixLocked(format: AVAudioFormat,
                                         capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let buf = reuseInputPrefix,
           buf.format.isEqual(format),
           buf.frameCapacity >= capacity {
            return buf
        }
        reuseInputPrefix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        return reuseInputPrefix
    }

    /// Caller MUST hold the lock. Returns the cached 48 kHz mono output
    /// buffer if capacity suffices; otherwise allocates fresh.
    private func ensureConvertedOutputLocked(capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let buf = reuseConvertedOutput, buf.frameCapacity >= capacity {
            return buf
        }
        reuseConvertedOutput = AVAudioPCMBuffer(pcmFormat: MumbleAudioParameters.pcmFormat,
                                                frameCapacity: capacity)
        return reuseConvertedOutput
    }

    /// Caller MUST hold the lock. Returns the cached 20 ms encode buffer
    /// (fixed at `framesPerPacket` samples), allocating once on first
    /// use.
    private func ensureEncodeFrameLocked() -> AVAudioPCMBuffer? {
        if let buf = reuseEncodeFrame {
            return buf
        }
        let cap = MumbleAudioParameters.framesPerPacket
        reuseEncodeFrame = AVAudioPCMBuffer(pcmFormat: MumbleAudioParameters.pcmFormat,
                                            frameCapacity: cap)
        return reuseEncodeFrame
    }
}

// AVAudioConverter's input block is `@Sendable`, but it's invoked
// synchronously from the same thread that called `convert(to:error:)`.
// `@unchecked Sendable` tells the compiler we've reasoned about that.
private final class ConvertOnce: @unchecked Sendable {
    var done = false
}

private final class Speaker {
    let decoder: OpusDecoder
    let player: AVAudioPlayerNode
    let format: AVAudioFormat

    init(decoder: OpusDecoder, player: AVAudioPlayerNode, format: AVAudioFormat) throws {
        self.decoder = decoder
        self.player = player
        self.format = format
    }
}
