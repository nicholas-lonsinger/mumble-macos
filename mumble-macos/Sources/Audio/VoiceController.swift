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

    /// Milliseconds to keep capturing + sending audio after `stopTransmit`
    /// is called. Without this linger, the last 0–100 ms of speech is
    /// dropped: the AVAudioEngine input tap delivers in chunks (~100 ms
    /// in a VM / over Bluetooth — see CLAUDE.md), so when the user
    /// releases the key the buffer carrying the final syllable is still
    /// in flight, and `handleCaptureBuffer` ignores it because
    /// `isTransmitting` already flipped to false. Mutated from main via
    /// `setReleaseLingerMS(_:)` and read on stop.
    private var releaseLingerMS: Int = 200
    /// True between `stopTransmit` (when linger > 0) and the deferred
    /// `finalizeLingeringStop`. While this is set, the capture tap keeps
    /// encoding/sending normally — `isTransmitting` stays true so the
    /// trailing audio buffer that arrives during the linger is captured
    /// rather than dropped.
    private var lingerActive = false
    /// Handle to the deferred-stop Task so `startTransmit` (re-press
    /// during linger) and `stop()` (engine teardown) can cancel it.
    private var lingerTask: Task<Void, Never>?

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
                         format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleCaptureBuffer(buffer)
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
        pendingSamples.removeAll()
        sendSequence = 0
        encoder = nil
        // Drop any pending release-linger so it doesn't fire a terminator
        // after the engine is gone.
        lingerActive = false
        taskToCancel = lingerTask
        lingerTask = nil
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

    /// Update the release-linger window. Read on the next `stopTransmit`,
    /// so changing this mid-burst takes effect on the next release.
    func setReleaseLingerMS(_ ms: Int) {
        lock.lock()
        releaseLingerMS = max(0, ms)
        lock.unlock()
    }

    // MARK: - Transmit (PTT)

    func startTransmit() {
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        // Re-press during the linger window: flush the previous burst's
        // trailing samples + terminator inline before opening a fresh
        // burst. Otherwise we'd inherit the previous burst's encoder
        // state and `burstTarget`, so a Whisper-A → release → Whisper-B
        // sequence could ship the start of B's audio under A's target.
        if lingerActive {
            lingerActive = false
            drainBurstLocked()
        }
        taskToCancel = lingerTask
        lingerTask = nil

        guard engineRunning else {
            lock.unlock()
            taskToCancel?.cancel()
            return
        }
        if isTransmitting {
            lock.unlock()
            taskToCancel?.cancel()
            return
        }
        do {
            encoder = try OpusEncoder()
        } catch {
            lock.unlock()
            taskToCancel?.cancel()
            Self.log.error("Opus encoder init failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        pendingSamples.removeAll()
        sendSequence = 0
        burstTarget = voiceTarget
        isTransmitting = true
        let target = burstTarget
        lock.unlock()
        taskToCancel?.cancel()
        Self.log.info("PTT transmit start (target=\(target, privacy: .public))")
    }

    func stopTransmit() {
        lock.lock()
        if !isTransmitting || lingerActive {
            // `lingerActive` set means a linger is already pending — a
            // duplicate stop call (e.g. multiple shortcuts releasing
            // back-to-back) is a no-op.
            lock.unlock()
            return
        }
        let lingerMS = releaseLingerMS
        if lingerMS <= 0 {
            // Linger disabled: drain synchronously, matching the pre-pref
            // behavior. The capture tap may still drop ~100 ms of trailing
            // audio in this mode, but the user has explicitly opted in.
            drainBurstLocked()
            lock.unlock()
            return
        }
        // Defer the actual finalize. While `lingerActive` is true,
        // `isTransmitting` stays true so the capture tap continues to
        // encode/send any audio that arrives during the linger window.
        //
        // The `lingerTask` write stays under the lock. If we unlocked
        // before assigning, a concurrent `startTransmit` could observe
        // the prior `lingerTask` value (or nil), drain, and clear the
        // task slot — and our pending assignment would land afterward
        // as a "ghost" task whose later wake-up would terminate the
        // *next* burst (saved only by the lingerActive flag check, but
        // a subsequent stopTransmit#2 could legitimately set
        // lingerActive=true and the ghost would steal #2's drain). The
        // `Task.init` itself is non-blocking, so holding the lock
        // across it is cheap.
        lingerActive = true
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lingerMS))
            if Task.isCancelled { return }
            self?.finalizeLingeringStop()
        }
        lock.unlock()
    }

    private func finalizeLingeringStop() {
        lock.lock()
        // The race we're guarding against: this Task wakes from sleep just
        // after `startTransmit` clears `lingerActive` and starts a fresh
        // burst. If we drained unconditionally we'd kill the new burst's
        // first frame. The flag check inside the lock is what makes this
        // idempotent — `startTransmit`'s drain already finalized us, so
        // we no-op.
        if lingerActive, isTransmitting {
            lingerActive = false
            drainBurstLocked()
        }
        lock.unlock()
    }

    /// Caller MUST hold the lock. Pads any partial trailing samples with
    /// silence to a full 20 ms frame and encodes one final packet (so the
    /// last <20 ms of speech isn't dropped on the boundary), emits both
    /// the trailing frame and the terminator via `onOpusFrame`, and
    /// resets transmit state. Idempotent — no-op when not transmitting.
    ///
    /// Yields to `onOpusFrame` happen under the lock. That's safe because
    /// the handler installed by `MumbleClient.startVoice` only does an
    /// `AsyncStream.Continuation.yield(_:)` (non-blocking, O(1) enqueue).
    /// Holding the lock across those yields is what defends the burst
    /// boundary from a concurrent `handleCaptureBuffer` slipping a
    /// new-burst frame between this drain's last frame and its
    /// terminator.
    private func drainBurstLocked() {
        guard isTransmitting else { return }
        let target = burstTarget
        let handler = onOpusFrame
        let framesPerPacket = Int(MumbleAudioParameters.framesPerPacket)

        if !pendingSamples.isEmpty,
           let encoder,
           let handler,
           let pcm = AVAudioPCMBuffer(pcmFormat: MumbleAudioParameters.pcmFormat,
                                      frameCapacity: AVAudioFrameCount(framesPerPacket)) {
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
                    handler(opus, seq, false, target)
                }
            } catch {
                Self.log.error("Opus encode (final pad) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let terminatorSeq = sendSequence
        Self.log.info("PTT transmit stop (frameNumber=\(terminatorSeq, privacy: .public) target=\(target, privacy: .public))")
        // Empty-payload terminator so the receiver finalizes playback.
        handler?(Data(), terminatorSeq, true, target)

        isTransmitting = false
        encoder = nil
        pendingSamples.removeAll()
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

    private func handleCaptureBuffer(_ buffer: AVAudioPCMBuffer) {
        let converted: AVAudioPCMBuffer
        if let inputConverter, let inputFormat {
            // Scale output capacity by the sample-rate ratio — otherwise
            // upsampling (e.g. 16 kHz Bluetooth mic → 48 kHz) truncates each
            // tap callback and audio comes out broken/muffled on the wire.
            let ratio = MumbleAudioParameters.sampleRate / inputFormat.sampleRate
            let inFrames = max(Int(buffer.frameLength), 1)
            let outCapacity = AVAudioFrameCount(Int((Double(inFrames) * ratio).rounded(.up)) + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: MumbleAudioParameters.pcmFormat,
                                             frameCapacity: outCapacity) else { return }
            // AVAudioConverter calls its input block synchronously, but Swift 6
            // strict concurrency can't see that — capturing a mutable `var`
            // here trips a Sendable diagnostic. Box the once-flag in a tiny
            // reference type to keep the closure capture-list happy.
            let once = ConvertOnce()
            var err: NSError?
            let status = inputConverter.convert(to: out, error: &err) { _, outStatus in
                if once.done {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                once.done = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error { return }
            converted = out
        } else {
            converted = buffer
        }

        guard let channelData = converted.floatChannelData?[0] else { return }
        let frameCount = Int(converted.frameLength)

        lock.lock()
        guard isTransmitting, let encoder else {
            lock.unlock()
            return
        }
        pendingSamples.reserveCapacity(pendingSamples.count + frameCount)
        pendingSamples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))

        let framesPerPacket = Int(MumbleAudioParameters.framesPerPacket)
        let burstTargetSnapshot = burstTarget
        var framesToSend: [(Data, UInt64)] = []
        while pendingSamples.count >= framesPerPacket {
            let slice = Array(pendingSamples.prefix(framesPerPacket))
            pendingSamples.removeFirst(framesPerPacket)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: MumbleAudioParameters.pcmFormat,
                                             frameCapacity: AVAudioFrameCount(framesPerPacket)) else {
                continue
            }
            pcm.frameLength = AVAudioFrameCount(framesPerPacket)
            if let dst = pcm.floatChannelData?[0] {
                slice.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: framesPerPacket)
                }
            }
            do {
                let opus = try encoder.encode(pcm)
                let seq = sendSequence
                sendSequence += MumbleAudioParameters.frameNumberStep
                if !opus.isEmpty {
                    framesToSend.append((opus, seq))
                }
            } catch {
                Self.log.error("Opus encode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let handler = onOpusFrame
        lock.unlock()

        if let handler {
            for (data, seq) in framesToSend {
                handler(data, seq, false, burstTargetSnapshot)
            }
        }
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
