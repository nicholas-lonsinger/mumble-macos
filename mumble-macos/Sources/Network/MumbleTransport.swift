import CryptoKit
import Foundation
import Network
import Security

enum MumbleTransportError: Error, Sendable, LocalizedError {
    case notConnected
    case remoteClosed
    case truncatedHeader(got: Int)
    case unexpectedShortRead(expected: Int, got: Int)
    case cancelled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a Mumble server."
        case .remoteClosed:
            return "The server closed the connection."
        case let .truncatedHeader(got):
            return "Truncated frame header: got \(got) bytes, expected \(MumbleFraming.headerSize)."
        case let .unexpectedShortRead(expected, got):
            return "Short read: expected \(expected) bytes, got \(got)."
        case .cancelled:
            return "The connection was cancelled."
        case let .underlying(message):
            return message
        }
    }
}

/// Async wrapper around NWConnection that speaks Mumble's framed TCP protocol over TLS.
///
/// Mumble servers commonly use self-signed certificates, so TLS verification is TOFU —
/// every presented certificate is accepted and its SHA-256 fingerprint is recorded so
/// higher layers can implement pinning later.
///
/// If a `clientIdentity` is provided, it's presented when the server requests a
/// client certificate. Mumble servers use this to identify returning users.
actor MumbleTransport {
    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let fingerprintBox: FingerprintBox
    private var ready = false
    private var pendingStart: CheckedContinuation<Void, Error>?
    private(set) var peerCertificateFingerprint: String?

    init(host: String, port: UInt16, clientIdentity: ClientIdentity? = nil) {
        let queue = DispatchQueue(label: "mumble.transport.\(host):\(port)")
        let fingerprintBox = FingerprintBox()
        let tlsOptions = Self.makeTLSOptions(clientIdentity: clientIdentity,
                                             fingerprintBox: fingerprintBox,
                                             queue: queue)
        let params = NWParameters(tls: tlsOptions, tcp: .init())

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            preconditionFailure("Invalid port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: nwPort)

        self.host = host
        self.port = port
        self.queue = queue
        self.fingerprintBox = fingerprintBox
        self.connection = NWConnection(to: endpoint, using: params)
    }

    deinit {
        connection.cancel()
    }

    func start() async throws {
        guard !ready else { return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateUpdate(state) }
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            connection.start(queue: queue)
        }
        peerCertificateFingerprint = fingerprintBox.fingerprint
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            pendingStart?.resume()
            pendingStart = nil
        case .failed(let error):
            ready = false
            pendingStart?.resume(throwing: MumbleTransportError.underlying(error.localizedDescription))
            pendingStart = nil
        case .cancelled:
            ready = false
            pendingStart?.resume(throwing: MumbleTransportError.cancelled)
            pendingStart = nil
        case .waiting(let error):
            // Path briefly unviable; fail fast so caller can surface something to the UI.
            pendingStart?.resume(throwing: MumbleTransportError.underlying(error.localizedDescription))
            pendingStart = nil
        default:
            break
        }
    }

    func cancel() {
        ready = false
        connection.cancel()
    }

    func send(_ data: Data) async throws {
        guard ready else { throw MumbleTransportError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MumbleTransportError.underlying(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func sendFrame<M: MumbleOutgoingMessage>(_ message: M) async throws {
        try await send(message.encodeFrame())
    }

    func sendFrame(type: MumbleMessageType, payload: Data) async throws {
        try await send(MumbleFraming.encode(type: type, payload: payload))
    }

    func receiveFrame() async throws -> (header: MumbleFraming.RawHeader, payload: Data) {
        let headerData = try await receiveExact(MumbleFraming.headerSize)
        let header: MumbleFraming.RawHeader
        do {
            header = try MumbleFraming.parseHeader(headerData)
        } catch MumbleFraming.FramingError.truncatedHeader(let got) {
            throw MumbleTransportError.truncatedHeader(got: got)
        }
        let payload: Data
        if header.payloadLength > 0 {
            payload = try await receiveExact(Int(header.payloadLength))
        } else {
            payload = Data()
        }
        return (header, payload)
    }

    private func receiveExact(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MumbleTransportError.underlying(error.localizedDescription))
                    return
                }
                if let data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: MumbleTransportError.remoteClosed)
                    return
                }
                continuation.resume(throwing: MumbleTransportError.unexpectedShortRead(expected: count, got: data?.count ?? 0))
            }
        }
    }

    // MARK: - TLS configuration

    private static func makeTLSOptions(clientIdentity: ClientIdentity?,
                                       fingerprintBox: FingerprintBox,
                                       queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        sec_protocol_options_set_verify_block(sec, { _, trust, completionHandler in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            fingerprintBox.recordFingerprint(from: secTrust)
            completionHandler(true)
        }, queue)

        if let clientIdentity {
            sec_protocol_options_set_challenge_block(sec, { _, complete in
                complete(sec_identity_create(clientIdentity.secIdentity))
            }, queue)
        }

        return options
    }
}

/// Thread-safe holder for the TLS fingerprint. The verify block runs on a Dispatch
/// queue outside the actor, so it can't await its way onto the actor — NSLock keeps
/// access safe.
private final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFingerprint: String?

    var fingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFingerprint
    }

    func recordFingerprint(from trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        storedFingerprint = hex
        lock.unlock()
    }
}
