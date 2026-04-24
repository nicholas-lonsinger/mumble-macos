@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

enum OpusCodecError: Error, Sendable, LocalizedError {
    case initializationFailed(Int32)
    case encodeFailed(Int32)
    case decodeFailed(Int32)
    case unsupportedInput

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let code):
            return "libopus failed to initialize (error \(code): \(Self.describe(code)))."
        case .encodeFailed(let code):
            return "libopus encode failed (error \(code): \(Self.describe(code)))."
        case .decodeFailed(let code):
            return "libopus decode failed (error \(code): \(Self.describe(code)))."
        case .unsupportedInput:
            return "Received audio in an unexpected format."
        }
    }

    private static func describe(_ code: Int32) -> String {
        if let cstr = opus_strerror(code) {
            return String(cString: cstr)
        }
        return "unknown"
    }
}

/// Audio parameters Mumble has standardized on. Opus frames in Mumble are 10 ms
/// multiples; we use 20 ms for a good latency/overhead balance.
enum MumbleAudioParameters {
    static let sampleRate: Double = 48_000
    static let channelCount: UInt32 = 1
    static let frameDurationSeconds: Double = 0.020
    static var framesPerPacket: AVAudioFrameCount {
        AVAudioFrameCount(sampleRate * frameDurationSeconds)
    }
    /// Largest Opus packet duration (120 ms @ 48 kHz = 5760 samples). Remote
    /// peers may ship frames longer than our 20 ms encode size, so decoder
    /// output buffers must be sized for the worst case or libopus returns
    /// OPUS_BUFFER_TOO_SMALL.
    static var maxDecodedFramesPerPacket: AVAudioFrameCount {
        AVAudioFrameCount(sampleRate * 0.120)
    }

    static var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: channelCount,
                      interleaved: false)!
    }
}

/// Encodes 48 kHz mono Float32 PCM into raw Opus packets. One instance is
/// bound to one outgoing voice stream; keep it across a PTT burst so the
/// encoder's internal state stays coherent.
final class OpusEncoder {
    private let encoder: OpaquePointer
    /// Worst-case compressed packet bound that Mumble + Opus both agree on.
    private static let maxPacketSize: Int = 4_000

    init(bitrate: Int32 = 32_000, application: Int32 = OPUS_APPLICATION_VOIP) throws {
        var error: Int32 = OPUS_OK
        guard let enc = opus_encoder_create(
            Int32(MumbleAudioParameters.sampleRate),
            Int32(MumbleAudioParameters.channelCount),
            application,
            &error
        ), error == OPUS_OK else {
            throw OpusCodecError.initializationFailed(error)
        }
        self.encoder = enc
        _ = mumble_opus_encoder_set_int(enc, Int32(OPUS_SET_BITRATE_REQUEST), bitrate)
        _ = mumble_opus_encoder_set_int(enc, Int32(OPUS_SET_SIGNAL_REQUEST), Int32(OPUS_SIGNAL_VOICE))
        _ = mumble_opus_encoder_set_int(enc, Int32(OPUS_SET_VBR_REQUEST), 1)
        // Inband FEC lets a receiver reconstruct one lost packet using
        // redundancy in the next — worth it for VoIP at the cost of slightly
        // higher bitrate.
        _ = mumble_opus_encoder_set_int(enc, Int32(OPUS_SET_INBAND_FEC_REQUEST), 1)
        _ = mumble_opus_encoder_set_int(enc, Int32(OPUS_SET_PACKET_LOSS_PERC_REQUEST), 5)
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// Consumes exactly one Opus packet worth of PCM (960 samples @ 48 kHz)
    /// and returns the raw Opus bytes.
    func encode(_ pcmBuffer: AVAudioPCMBuffer) throws -> Data {
        guard let channel = pcmBuffer.floatChannelData?[0] else {
            throw OpusCodecError.unsupportedInput
        }
        let frameCount = Int32(MumbleAudioParameters.framesPerPacket)
        guard Int(pcmBuffer.frameLength) >= Int(frameCount) else {
            throw OpusCodecError.unsupportedInput
        }
        var output = [UInt8](repeating: 0, count: Self.maxPacketSize)
        let written = output.withUnsafeMutableBufferPointer { out in
            opus_encode_float(encoder,
                              channel,
                              frameCount,
                              out.baseAddress,
                              Int32(out.count))
        }
        if written < 0 {
            throw OpusCodecError.encodeFailed(written)
        }
        return Data(output.prefix(Int(written)))
    }
}

/// Decodes a single Opus packet back to 48 kHz mono Float32 PCM. Each remote
/// speaker gets their own decoder so PLC state stays per-stream.
final class OpusDecoder {
    private let decoder: OpaquePointer

    init() throws {
        var error: Int32 = OPUS_OK
        guard let dec = opus_decoder_create(
            Int32(MumbleAudioParameters.sampleRate),
            Int32(MumbleAudioParameters.channelCount),
            &error
        ), error == OPUS_OK else {
            throw OpusCodecError.initializationFailed(error)
        }
        self.decoder = dec
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Pass an empty `opusData` to request packet loss concealment for one
    /// missing frame.
    func decode(_ opusData: Data, fec: Bool = false) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: MumbleAudioParameters.pcmFormat,
            frameCapacity: MumbleAudioParameters.maxDecodedFramesPerPacket
        ), let dst = output.floatChannelData?[0] else {
            throw OpusCodecError.decodeFailed(-1)
        }
        let produced: Int32
        if opusData.isEmpty {
            // PLC / FEC path: frame_size must equal the duration of the
            // missing audio. We assume our own 20 ms packet cadence for the
            // gap.
            produced = opus_decode_float(decoder,
                                         nil,
                                         0,
                                         dst,
                                         Int32(MumbleAudioParameters.framesPerPacket),
                                         fec ? 1 : 0)
        } else {
            produced = opusData.withUnsafeBytes { raw -> Int32 in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                return opus_decode_float(decoder,
                                         base,
                                         Int32(raw.count),
                                         dst,
                                         Int32(MumbleAudioParameters.maxDecodedFramesPerPacket),
                                         fec ? 1 : 0)
            }
        }
        if produced < 0 {
            throw OpusCodecError.decodeFailed(produced)
        }
        output.frameLength = AVAudioFrameCount(produced)
        return output
    }
}
