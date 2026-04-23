import Foundation
import Observation

@MainActor
@Observable
final class MumbleClient {
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case handshaking
        case connected
        case failed(reason: String)
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var serverWelcomeText: String = ""
    private(set) var lastError: String?
    private(set) var channels: [UInt32: ChannelNode] = [:]
    private(set) var users: [UInt32: UserNode] = [:]
    private(set) var rootChannelID: UInt32?
    private(set) var sessionID: UInt32?

    func connect(to parameters: ServerConnectionParameters) async {
        // Placeholder — real implementation lands with the TLS / handshake tasks.
        state = .connecting
    }

    func disconnect() async {
        state = .disconnected
        channels.removeAll()
        users.removeAll()
        rootChannelID = nil
        sessionID = nil
        serverWelcomeText = ""
    }
}
