import Foundation
import Observation
import OSLog

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
    private(set) var serverVersion: String?
    private(set) var serverCertificateFingerprint: String?
    private(set) var lastError: String?
    private(set) var channels: [UInt32: ChannelNode] = [:]
    private(set) var users: [UInt32: UserNode] = [:]
    private(set) var rootChannelID: UInt32?
    private(set) var sessionID: UInt32?

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "client")

    private static let protocolMajor: UInt16 = 1
    private static let protocolMinor: UInt16 = 5
    private static let protocolPatch: UInt16 = 0
    private static let clientRelease: String = "mumble-macos"
    private static let pingInterval: Duration = .seconds(20)
    private static let connectTimeout: Duration = .seconds(10)

    private var transport: MumbleTransport?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var currentParameters: ServerConnectionParameters?

    func connect(to parameters: ServerConnectionParameters) async {
        await disconnect()
        state = .connecting
        lastError = nil
        currentParameters = parameters

        let transport = MumbleTransport(host: parameters.host, port: parameters.port)
        self.transport = transport

        do {
            try await Self.withTimeout(Self.connectTimeout,
                                       operation: { try await transport.start() },
                                       errorMessage: "Couldn't reach \(parameters.host):\(parameters.port) within \(Int(Self.connectTimeout.components.seconds)) seconds.")
            serverCertificateFingerprint = await transport.peerCertificateFingerprint
            state = .handshaking

            try await sendVersion(transport: transport)
            try await sendAuthenticate(transport: transport, parameters: parameters)

            startReceiveLoop(transport: transport)
            startPingLoop(transport: transport)
        } catch {
            state = .failed(reason: error.localizedDescription)
            lastError = error.localizedDescription
            await teardown()
        }
    }

    private static func withTimeout(_ timeout: Duration,
                                    operation: @Sendable @escaping () async throws -> Void,
                                    errorMessage: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MumbleTransportError.underlying(errorMessage)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func disconnect() async {
        if state != .disconnected {
            state = .disconnected
        }
        await teardown()
        channels.removeAll()
        users.removeAll()
        rootChannelID = nil
        sessionID = nil
        serverWelcomeText = ""
        serverVersion = nil
    }

    private func teardown() async {
        receiveTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        pingTask = nil
        if let transport {
            await transport.cancel()
        }
        transport = nil
    }

    // MARK: - Outbound handshake

    private func sendVersion(transport: MumbleTransport) async throws {
        let v2 = MumbleVersion.fullVersionV2(
            major: Self.protocolMajor,
            minor: Self.protocolMinor,
            patch: Self.protocolPatch
        )
        let v1 = MumbleVersion.legacyVersionV1(
            major: Self.protocolMajor,
            minor: UInt8(clamping: Self.protocolMinor),
            patch: UInt8(clamping: Self.protocolPatch)
        )
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let msg = VersionMessage(
            versionV1: v1,
            versionV2: v2,
            release: Self.clientRelease,
            os: "macOS",
            osVersion: osVersion
        )
        try await transport.sendFrame(msg)
    }

    private func sendAuthenticate(transport: MumbleTransport,
                                  parameters: ServerConnectionParameters) async throws {
        let auth = AuthenticateMessage(
            username: parameters.username,
            password: parameters.password,
            tokens: [],
            celtVersions: [],
            opus: true,
            clientType: 0
        )
        try await transport.sendFrame(auth)
    }

    // MARK: - Receive loop

    private func startReceiveLoop(transport: MumbleTransport) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let (header, payload) = try await transport.receiveFrame()
                    await self?.handleFrame(header: header, payload: payload)
                } catch {
                    if Task.isCancelled { return }
                    await self?.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) async {
        if state != .disconnected {
            state = .failed(reason: error.localizedDescription)
            lastError = error.localizedDescription
        }
        await teardown()
    }

    private func handleFrame(header: MumbleFraming.Header, payload: Data) async {
        var reader = ProtobufReader(payload)
        do {
            switch header.type {
            case .version:
                let msg = try VersionMessage(reader: &reader)
                if let v2 = msg.versionV2 {
                    let c = MumbleVersion.components(fromV2: v2)
                    serverVersion = "\(c.major).\(c.minor).\(c.patch)"
                }
            case .reject:
                let msg = try RejectMessage(reader: &reader)
                state = .failed(reason: msg.humanDescription)
                lastError = msg.humanDescription
                await teardown()
            case .serverSync:
                let msg = try ServerSyncMessage(reader: &reader)
                sessionID = msg.session
                if let welcome = msg.welcomeText { serverWelcomeText = welcome }
                state = .connected
            case .channelState:
                let msg = try ChannelStateMessage(reader: &reader)
                applyChannelState(msg)
            case .channelRemove:
                let msg = try ChannelRemoveMessage(reader: &reader)
                removeChannel(id: msg.channelID)
            case .userState:
                let msg = try UserStateMessage(reader: &reader)
                applyUserState(msg)
            case .userRemove:
                let msg = try UserRemoveMessage(reader: &reader)
                removeUser(session: msg.session)
            case .textMessage:
                _ = try TextMessageMessage(reader: &reader)
                // TODO: surface chat messages to the UI
            case .ping:
                _ = try PingMessage(reader: &reader)
            case .serverConfig:
                let msg = try ServerConfigMessage(reader: &reader)
                if let welcome = msg.welcomeText, serverWelcomeText.isEmpty {
                    serverWelcomeText = welcome
                }
            case .codecVersion:
                _ = try CodecVersionMessage(reader: &reader)
            case .cryptSetup:
                _ = try CryptSetupMessage(reader: &reader)
                // UDP crypto material — stashed for when we wire up UDP audio.
            case .permissionDenied:
                let msg = try PermissionDeniedMessage(reader: &reader)
                Self.log.warning("Permission denied: \(msg.reason ?? "(no reason)")")
            default:
                Self.log.debug("Ignoring message type \(header.type.rawValue, privacy: .public)")
            }
        } catch {
            Self.log.error("Failed to decode \(String(describing: header.type), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Channel and user model mutations

    private func applyChannelState(_ msg: ChannelStateMessage) {
        guard let id = msg.channelID else { return }
        if var existing = channels[id] {
            if let name = msg.name { existing.name = name }
            if let parent = msg.parent {
                detachChild(id, from: existing.parentID)
                existing.parentID = parent
                attachChild(id, to: parent)
            }
            if let description = msg.description { existing.description = description }
            if let temporary = msg.temporary { existing.isTemporary = temporary }
            if let position = msg.position { existing.position = position }
            if let maxUsers = msg.maxUsers { existing.maxUsers = maxUsers }
            channels[id] = existing
        } else {
            let node = ChannelNode(
                id: id,
                name: msg.name ?? "",
                parentID: msg.parent,
                description: msg.description,
                isTemporary: msg.temporary ?? false,
                position: msg.position ?? 0,
                maxUsers: msg.maxUsers ?? 0,
                childChannelIDs: [],
                userSessionIDs: []
            )
            channels[id] = node
            if let parent = msg.parent {
                attachChild(id, to: parent)
            } else if rootChannelID == nil {
                rootChannelID = id
            }
        }
    }

    private func attachChild(_ childID: UInt32, to parentID: UInt32) {
        guard var parent = channels[parentID] else { return }
        if !parent.childChannelIDs.contains(childID) {
            parent.childChannelIDs.append(childID)
            channels[parentID] = parent
        }
    }

    private func detachChild(_ childID: UInt32, from parentID: UInt32?) {
        guard let parentID, var parent = channels[parentID] else { return }
        parent.childChannelIDs.removeAll(where: { $0 == childID })
        channels[parentID] = parent
    }

    private func removeChannel(id: UInt32) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        detachChild(id, from: channel.parentID)
        if rootChannelID == id {
            rootChannelID = nil
        }
    }

    private func applyUserState(_ msg: UserStateMessage) {
        guard let session = msg.session else { return }
        if var existing = users[session] {
            if let name = msg.name { existing.name = name }
            if let channelID = msg.channelID, existing.channelID != channelID {
                moveUser(session: session, from: existing.channelID, to: channelID)
                existing.channelID = channelID
            }
            if let userID = msg.userID { existing.userID = userID }
            if let mute = msg.mute { existing.isMuted = mute }
            if let deaf = msg.deaf { existing.isDeafened = deaf }
            if let selfMute = msg.selfMute { existing.isSelfMuted = selfMute }
            if let selfDeaf = msg.selfDeaf { existing.isSelfDeafened = selfDeaf }
            if let suppress = msg.suppress { existing.isSuppressed = suppress }
            if let priority = msg.prioritySpeaker { existing.isPrioritySpeaker = priority }
            if let recording = msg.recording { existing.isRecording = recording }
            if let comment = msg.comment { existing.comment = comment }
            if let hash = msg.hash { existing.hash = hash }
            users[session] = existing
        } else {
            let node = UserNode(
                id: session,
                name: msg.name ?? "",
                channelID: msg.channelID ?? rootChannelID ?? 0,
                userID: msg.userID,
                isMuted: msg.mute ?? false,
                isDeafened: msg.deaf ?? false,
                isSelfMuted: msg.selfMute ?? false,
                isSelfDeafened: msg.selfDeaf ?? false,
                isSuppressed: msg.suppress ?? false,
                isPrioritySpeaker: msg.prioritySpeaker ?? false,
                isRecording: msg.recording ?? false,
                comment: msg.comment,
                hash: msg.hash
            )
            users[session] = node
            attachUser(session: session, to: node.channelID)
        }
    }

    private func attachUser(session: UInt32, to channelID: UInt32) {
        guard var channel = channels[channelID] else { return }
        if !channel.userSessionIDs.contains(session) {
            channel.userSessionIDs.append(session)
            channels[channelID] = channel
        }
    }

    private func detachUser(session: UInt32, from channelID: UInt32) {
        guard var channel = channels[channelID] else { return }
        channel.userSessionIDs.removeAll(where: { $0 == session })
        channels[channelID] = channel
    }

    private func moveUser(session: UInt32, from oldChannelID: UInt32, to newChannelID: UInt32) {
        detachUser(session: session, from: oldChannelID)
        attachUser(session: session, to: newChannelID)
    }

    private func removeUser(session: UInt32) {
        guard let user = users.removeValue(forKey: session) else { return }
        detachUser(session: session, from: user.channelID)
    }

    // MARK: - Keepalive ping

    private func startPingLoop(transport: MumbleTransport) {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pingInterval)
                    if Task.isCancelled { return }
                    let ping = PingMessage(timestamp: UInt64(Date().timeIntervalSince1970 * 1_000_000))
                    try await transport.sendFrame(ping)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.handleReceiveFailure(error)
                    return
                }
            }
        }
    }
}
