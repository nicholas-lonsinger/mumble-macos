@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

enum OpusCodecError: Error, Sendable, LocalizedError {
    case formatUnavailable
    case converterCreationFailed(OSStatus)
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case unsupportedInput

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "Couldn't construct an AVAudioFormat for Opus — macOS may not expose the encoder on this system."
        case .converterCreationFailed(let status):
            return "AVAudioConverter initialization failed (OSStatus \(status))."
        case .encodeFailed(let status):
            return "Opus encode failed (OSStatus \(status))."
        case .decodeFailed(let status):
            return "Opus decode failed (OSStatus \(status))."
        case .unsupportedInput:
            return "Received audio in an unexpected format."
        }
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

    static var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: channelCount,
                      interleaved: false)!
    }

    static func opusFormat() -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &asbd)
    }
}

/// Encodes 48 kHz mono Float32 PCM into Opus frames. One instance is bound to
/// one outgoing voice stream; keep it around for the lifetime of a PTT burst
/// so the encoder stays stateful.
final class OpusEncoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    /// Worst-case compressed packet bound — 4000 bytes is the Opus spec ceiling
    /// and what the reference implementation reserves.
    private static let maxPacketSize: UInt32 = 4_000

    init(bitrate: Int32 = 32_000) throws {
        guard let opusFormat = MumbleAudioParameters.opusFormat() else {
            throw OpusCodecError.formatUnavailable
        }
        let pcmFormat = MumbleAudioParameters.pcmFormat

        guard let converter = AVAudioConverter(from: pcmFormat, to: opusFormat) else {
            throw OpusCodecError.converterCreationFailed(0)
        }
        converter.bitRate = Int(bitrate)
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.opusFormat = opusFormat
    }

    /// Consumes exactly one Opus packet worth of PCM (960 samples @ 48 kHz) and
    /// returns the compressed Opus bytes.
    func encode(_ pcmBuffer: AVAudioPCMBuffer) throws -> Data {
        let output = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: Int(Self.maxPacketSize)
        )
        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        switch status {
        case .haveData, .inputRanDry:
            break
        case .error, .endOfStream:
            throw OpusCodecError.encodeFailed(OSStatus(error?.code ?? -1))
        @unknown default:
            throw OpusCodecError.encodeFailed(-1)
        }
        guard output.packetCount > 0,
              let packetDesc = output.packetDescriptions else {
            return Data()
        }
        let size = Int(packetDesc.pointee.mDataByteSize)
        let bytes = UnsafeRawBufferPointer(start: output.data, count: size)
        return Data(bytes)
    }
}

/// Decodes a single Opus frame back to 48 kHz mono Float32 PCM. Each remote
/// speaker gets their own decoder so PLC state stays per-stream.
final class OpusDecoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat

    init() throws {
        guard let opusFormat = MumbleAudioParameters.opusFormat() else {
            throw OpusCodecError.formatUnavailable
        }
        let pcmFormat = MumbleAudioParameters.pcmFormat
        guard let converter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw OpusCodecError.converterCreationFailed(0)
        }
        self.converter = converter
        self.pcmFormat = pcmFormat
        self.opusFormat = opusFormat
    }

    func decode(_ opusData: Data) throws -> AVAudioPCMBuffer {
        let input = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: opusData.count > 0 ? opusData.count : 1
        )
        input.byteLength = UInt32(opusData.count)
        input.packetCount = 1
        opusData.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(input.data, base, opusData.count)
            }
        }
        if let desc = input.packetDescriptions {
            desc.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(opusData.count)
            )
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: MumbleAudioParameters.framesPerPacket
        ) else {
            throw OpusCodecError.decodeFailed(-1)
        }
        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return input
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw OpusCodecError.decodeFailed(OSStatus(error?.code ?? -1))
        @unknown default:
            throw OpusCodecError.decodeFailed(-1)
        }
        return output
    }
}
