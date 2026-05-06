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
        lock.lock(); defer { lock.unlock() }
        if !engineRunning { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        speakers.values.forEach { $0.player.stop() }
        speakers.removeAll()
        isTransmitting = false
        pendingSamples.removeAll()
        sendSequence = 0
        encoder = nil
        Self.log.info("Audio engine stopped")
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
        lock.lock(); defer { lock.unlock() }
        guard engineRunning else { return }
        if isTransmitting { return }
        do {
            encoder = try OpusEncoder()
        } catch {
            Self.log.error("Opus encoder init failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        pendingSamples.removeAll()
        sendSequence = 0
        burstTarget = voiceTarget
        isTransmitting = true
        Self.log.info("PTT transmit start (target=\(self.burstTarget, privacy: .public))")
    }

    func stopTransmit() {
        let handler: OpusFrameHandler?
        let terminatorSeq: UInt64?
        let terminatorTarget: UInt32
        lock.lock()
        if !isTransmitting {
            lock.unlock()
            return
        }
        isTransmitting = false
        handler = onOpusFrame
        let seq = sendSequence
        terminatorSeq = seq
        terminatorTarget = burstTarget
        encoder = nil
        pendingSamples.removeAll()
        lock.unlock()

        Self.log.info("PTT transmit stop (frameNumber=\(terminatorSeq ?? 0, privacy: .public) target=\(terminatorTarget, privacy: .public))")
        // Send an empty-payload terminator so the server knows the burst ended.
        if let handler, let terminatorSeq {
            handler(Data(), terminatorSeq, true, terminatorTarget)
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
