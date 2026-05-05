import AVFoundation
import XCTest
@testable import mumble_macos

/// End-to-end Opus encode → decode sanity checks. The build can't catch a
/// codec that produces *decodable-but-wrong* audio (all-zeros, all-noise,
/// frame-count drift) — exactly the failure mode a NEON regression or a
/// libopus version bump could introduce. These tests don't assert
/// bit-for-bit equality (libopus is lossy and tunes by version); they
/// assert the gross properties any sane codec preserves: silence stays
/// quiet, signal stays loud, frame counts match the 20 ms cadence we
/// negotiate on the wire.
final class OpusCodecRoundtripTests: XCTestCase {

    private static let framesPerPacket = Int(MumbleAudioParameters.framesPerPacket)
    private static let sampleRate = MumbleAudioParameters.sampleRate

    // MARK: - Helpers

    private func makeBuffer(filledBy generator: (Int) -> Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: MumbleAudioParameters.pcmFormat,
            frameCapacity: AVAudioFrameCount(Self.framesPerPacket)
        )!
        buffer.frameLength = AVAudioFrameCount(Self.framesPerPacket)
        let channel = buffer.floatChannelData![0]
        for i in 0..<Self.framesPerPacket {
            channel[i] = generator(i)
        }
        return buffer
    }

    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let channel = buffer.floatChannelData![0]
        let n = Int(buffer.frameLength)
        var sumSquares: Double = 0
        for i in 0..<n {
            let sample = Double(channel[i])
            sumSquares += sample * sample
        }
        return Float(sqrt(sumSquares / Double(max(n, 1))))
    }

    private func peakAbs(of buffer: AVAudioPCMBuffer) -> Float {
        let channel = buffer.floatChannelData![0]
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<n {
            peak = max(peak, abs(channel[i]))
        }
        return peak
    }

    // MARK: - Encoder sanity

    func test_encodeSilence_producesNonemptyPacket() throws {
        let encoder = try OpusEncoder()
        let silence = makeBuffer { _ in 0 }
        let packet = try encoder.encode(silence)
        // Even a "silence" Opus packet has a frame header — never zero bytes.
        XCTAssertGreaterThan(packet.count, 0)
        // 20 ms of silence at our 32 kbps target compresses to a tiny packet
        // (single-digit bytes). The cap is loose so legitimate VBR jitter
        // doesn't fail the test, but catches "encoder returned a giant
        // garbage buffer."
        XCTAssertLessThan(packet.count, 80, "silence packet ballooned — encoder regression?")
    }

    func test_encodeSineWave_producesPlausiblePacketSize() throws {
        let encoder = try OpusEncoder()
        // 1 kHz @ amplitude 0.5 is well inside Opus's voice-mode comfort zone.
        let tone = makeBuffer { i in
            0.5 * sinf(2 * .pi * 1000 * Float(i) / Float(Self.sampleRate))
        }
        let packet = try encoder.encode(tone)
        // Tone at 32 kbps VBR settles around ~80 bytes per 20 ms packet;
        // the bounds are loose to absorb VBR variance + libopus version drift.
        XCTAssertGreaterThan(packet.count, 20)
        XCTAssertLessThan(packet.count, 200)
    }

    // MARK: - Decoder shape

    func test_decode_returns20msFrame() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        let tone = makeBuffer { i in
            0.5 * sinf(2 * .pi * 1000 * Float(i) / Float(Self.sampleRate))
        }
        let packet = try encoder.encode(tone)
        let decoded = try decoder.decode(packet)
        // The wire-side invariant Mumble depends on: a 20 ms packet decodes
        // to exactly 960 samples at 48 kHz.
        XCTAssertEqual(Int(decoded.frameLength), Self.framesPerPacket)
    }

    func test_decode_emptyPacketRequestsPLC() throws {
        let decoder = try OpusDecoder()
        // Empty data path triggers libopus's packet-loss concealment for
        // a single 20 ms gap. Should produce a full frame, not error out.
        let plc = try decoder.decode(Data())
        XCTAssertEqual(Int(plc.frameLength), Self.framesPerPacket)
    }

    // MARK: - Roundtrip energy

    func test_roundtripSilence_decodesToNearSilence() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        let silence = makeBuffer { _ in 0 }

        // Warm up the codec — Opus has algorithmic lookahead/delay on the
        // first few packets, so steady-state behavior shows up after a
        // couple of frames. Mumble's PTT bursts always run multi-packet
        // anyway, so this matches real use.
        for _ in 0..<3 {
            let packet = try encoder.encode(silence)
            _ = try decoder.decode(packet)
        }

        let packet = try encoder.encode(silence)
        let decoded = try decoder.decode(packet)
        let peak = peakAbs(of: decoded)
        // Silence in → near-silence out. Threshold is generous; the
        // failure modes we want to catch (NEON producing constant nonzero
        // garbage) overshoot this by orders of magnitude.
        XCTAssertLessThan(peak, 0.01,
                          "silence roundtrip leaked energy — peak abs \(peak)")
    }

    func test_roundtripSineWave_preservesEnergy() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        // 1 kHz sine at 0.5 amplitude → input RMS = 0.5 / sqrt(2) ≈ 0.354.
        let generator: (Int) -> Float = { i in
            0.5 * sinf(2 * .pi * 1000 * Float(i) / Float(Self.sampleRate))
        }
        let inputRMS = Float(0.5 / sqrt(2.0))

        // Warm up past the encoder's lookahead window.
        for _ in 0..<3 {
            let packet = try encoder.encode(makeBuffer(filledBy: generator))
            _ = try decoder.decode(packet)
        }

        let packet = try encoder.encode(makeBuffer(filledBy: generator))
        let decoded = try decoder.decode(packet)
        let outputRMS = rms(of: decoded)

        // Voice-mode Opus at 32 kbps preserves a 1 kHz tone faithfully —
        // RMS should land within ±50% of input. Generous bounds catch the
        // failures we care about (output near zero, output saturating)
        // without rejecting legitimate codec variance.
        XCTAssertGreaterThan(outputRMS, inputRMS * 0.5,
                             "sine wave decoded too quietly — RMS \(outputRMS) vs input \(inputRMS)")
        XCTAssertLessThan(outputRMS, inputRMS * 1.5,
                          "sine wave decoded too loudly — RMS \(outputRMS) vs input \(inputRMS)")
    }

    // MARK: - Multi-packet stability

    func test_multiPacketRoundtrip_frameCountStaysExact() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        let silence = makeBuffer { _ in 0 }
        // Cycle a full second of audio through the codec and confirm every
        // decoded packet is exactly one 20 ms frame. A NEON regression that
        // smuggled extra samples or dropped them would surface here.
        for _ in 0..<50 {
            let packet = try encoder.encode(silence)
            let decoded = try decoder.decode(packet)
            XCTAssertEqual(Int(decoded.frameLength), Self.framesPerPacket)
        }
    }
}
