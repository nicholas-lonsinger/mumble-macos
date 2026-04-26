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
    private var voiceSendTask: Task<Void, Never>?
    private var voiceSendContinuation: AsyncStream<VoiceSendItem>.Continuation?
    private var currentParameters: ServerConnectionParameters?
    private let voice = VoiceController()
    private(set) var voiceAvailable = false
    private(set) var isTransmitting = false
    /// Per-packet `MumbleUDP.Audio.target`. 0 = normal talk, 1..30 =
    /// whisper via the matching `VoiceTarget` slot, 31 = server loopback.
    /// Set non-zero by `applyWhisperTarget` when a Whisper/Shout shortcut is
    /// active; otherwise stays at 0 so plain PTT goes to the user's channel.
    private(set) var outgoingVoiceTarget: UInt32 = 0
    private(set) var speakingSessions: Set<UInt32> = []
    private var speakingClearTasks: [UInt32: Task<Void, Never>] = [:]
    private var connectStartedAt: ContinuousClock.Instant?

    private struct VoiceSendItem: Sendable {
        let opus: Data
        let frameNumber: UInt64
        let isTerminator: Bool
    }

    func connect(to parameters: ServerConnectionParameters) async {
        await disconnect()
        state = .connecting
        lastError = nil
        currentParameters = parameters
        Self.log.info("Connecting to \(parameters.host, privacy: .public):\(parameters.port, privacy: .public) as \(parameters.username, privacy: .public)")
        connectStartedAt = .now

        // If the user has configured a client identity, present it during the
        // TLS handshake. A keychain read failure is logged and downgraded to
        // "connect unauthenticated" — we'd rather fall back to guest than
        // refuse to connect.
        var identity: ClientIdentity?
        do {
            identity = try IdentityStore.shared.currentIdentity()
            if identity != nil {
                Self.log.info("Presenting stored client identity during TLS handshake.")
            }
        } catch {
            Self.log.error("Identity lookup failed, continuing without client cert: \(error.localizedDescription, privacy: .public)")
        }

        let transport = MumbleTransport(host: parameters.host, port: parameters.port, clientIdentity: identity)
        self.transport = transport

        do {
            try await Self.withTimeout(Self.connectTimeout,
                                       operation: { try await transport.start() },
                                       errorMessage: "Couldn't reach \(parameters.host):\(parameters.port) within \(Int(Self.connectTimeout.components.seconds)) seconds.")
            serverCertificateFingerprint = await transport.peerCertificateFingerprint
            state = .handshaking
            if let fp = serverCertificateFingerprint {
                Self.log.info("TLS established, peer cert SHA-256 \(fp, privacy: .public)")
            }

            try await sendVersion(transport: transport)
            try await sendAuthenticate(transport: transport, parameters: parameters)

            startReceiveLoop(transport: transport)
            startPingLoop(transport: transport)
            startVoice(transport: transport)
        } catch {
            Self.log.error("Connect failed: \(error.localizedDescription, privacy: .public)")
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
        let wasActive = state != .disconnected
        if wasActive {
            state = .disconnected
            Self.log.info("Disconnecting (user-initiated)")
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
        voice.onOpusFrame = nil
        voice.stop()
        voiceSendContinuation?.finish()
        voiceSendContinuation = nil
        voiceSendTask?.cancel()
        voiceSendTask = nil
        voiceAvailable = false
        isTransmitting = false
        for (_, task) in speakingClearTasks { task.cancel() }
        speakingClearTasks.removeAll()
        speakingSessions.removeAll()
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
                    try await self?.handleFrame(header: header, payload: payload)
                } catch {
                    if Task.isCancelled { return }
                    await self?.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) async {
        Self.log.error("Receive loop failed: \(error.localizedDescription, privacy: .public)")
        if state != .disconnected {
            state = .failed(reason: error.localizedDescription)
            lastError = error.localizedDescription
        }
        await teardown()
    }

    private func handleFrame(header: MumbleFraming.RawHeader, payload: Data) async throws {
        guard let type = header.type else {
            throw MumbleProtocolError.unknownMessageType(
                rawType: header.rawType,
                payloadLength: header.payloadLength,
                payloadPreview: Self.hexPreview(payload, max: 32)
            )
        }
        var reader = ProtobufReader(payload)
        do {
            switch type {
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
                let elapsed = connectStartedAt.map { ContinuousClock.now - $0 } ?? .zero
                let ms = Int(elapsed.components.seconds) * 1_000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                Self.log.info("ServerSync received — session=\(msg.session ?? 0, privacy: .public), channels=\(self.channels.count, privacy: .public), users=\(self.users.count, privacy: .public), handshake=\(ms, privacy: .public)ms")
                await tryJoinDesiredChannelAfterSync()
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
            case .udpTunnel:
                handleTunneledAudio(payload: payload)
            case .authenticate,
                 .banList,
                 .acl,
                 .queryUsers,
                 .contextActionModify,
                 .contextAction,
                 .userList,
                 .voiceTarget,
                 .permissionQuery,
                 .userStats,
                 .requestBlob,
                 .suggestConfig,
                 .pluginDataTransmission:
                // Known message type that we don't consume yet. Logged explicitly so it's
                // obvious when something we've ignored actually shows up on the wire.
                Self.log.info("Received \(String(describing: type), privacy: .public) (\(payload.count) bytes), not yet handled")
            }
        } catch let error as ProtobufError {
            throw MumbleProtocolError.messageDecodeFailed(
                type: type,
                payloadLength: header.payloadLength,
                payloadPreview: Self.hexPreview(payload, max: 32),
                underlying: error
            )
        }
    }

    private static func hexPreview(_ data: Data, max: Int) -> String {
        let limit = Swift.min(data.count, max)
        let prefix = data.prefix(limit)
        let hex = prefix.map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > limit ? "\(hex) …" : hex
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
        speakingClearTasks[session]?.cancel()
        speakingClearTasks[session] = nil
        speakingSessions.remove(session)
        voice.removeSpeaker(session: session)
    }

    // MARK: - Voice

    private func startVoice(transport: MumbleTransport) {
        // Serialize outgoing voice frames through a single consumer task so
        // they hit the TLS socket in encoder order. Spawning one Task per
        // frame doesn't guarantee FIFO start order (Swift concurrency is
        // cooperative, not insertion-ordered), which can reorder audio on the
        // wire and garble remote playback.
        //
        // Also pace sends at the frame cadence (20 ms). The AVAudioEngine
        // input tap inside a VM / over Bluetooth delivers ~100 ms buffers at
        // a time, which produces 5 encoded packets in a ~1 ms burst. Sent
        // as a burst, the receiver's jitter buffer sees long arrival gaps,
        // runs dry, and fills with PLC/silence — which sounds exactly like
        // "broken and muffled." Pacing smooths arrivals to the expected rate.
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceSendItem.self,
                                                            bufferingPolicy: .unbounded)
        voiceSendContinuation = continuation
        voiceSendTask = Task { [weak self, transport] in
            let clock = ContinuousClock()
            let frameSpacing: Duration = .milliseconds(20)
            var nextSendAt: ContinuousClock.Instant?
            for await item in stream {
                let now = clock.now
                let scheduledAt: ContinuousClock.Instant
                if let target = nextSendAt, target > now {
                    try? await clock.sleep(until: target)
                    scheduledAt = target
                } else {
                    scheduledAt = now
                }
                await self?.sendVoiceFrame(transport: transport,
                                           opus: item.opus,
                                           frameNumber: item.frameNumber,
                                           isTerminator: item.isTerminator)
                nextSendAt = scheduledAt + frameSpacing
            }
        }
        voice.onOpusFrame = { opus, frameNumber, isTerminator in
            continuation.yield(VoiceSendItem(opus: opus,
                                             frameNumber: frameNumber,
                                             isTerminator: isTerminator))
        }
        do {
            try voice.start()
            voiceAvailable = true
        } catch {
            Self.log.error("Voice engine failed to start: \(error.localizedDescription, privacy: .public)")
            voiceAvailable = false
        }
    }

    private func sendVoiceFrame(transport: MumbleTransport,
                                opus: Data,
                                frameNumber: UInt64,
                                isTerminator: Bool) async {
        let audio = UDPAudioMessage(target: outgoingVoiceTarget,
                                    frameNumber: frameNumber,
                                    opusData: opus,
                                    isTerminator: isTerminator)
        do {
            try await transport.sendFrame(type: .udpTunnel,
                                          payload: audio.tunneledPacket())
        } catch {
            Self.log.error("Voice send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startTalking() {
        guard voiceAvailable, case .connected = state else { return }
        voice.startTransmit()
        isTransmitting = true
    }

    func stopTalking() {
        voice.stopTransmit()
        isTransmitting = false
    }

    private func handleTunneledAudio(payload: Data) {
        do {
            guard let audio = try UDPAudioMessage.decode(tunneled: payload) else {
                Self.log.debug("UDPTunnel carried non-audio payload of \(payload.count, privacy: .public) bytes")
                return
            }
            guard let session = audio.senderSession else { return }
            voice.ingestRemoteAudio(session: session,
                                    opus: audio.opusData,
                                    frameNumber: audio.frameNumber ?? 0,
                                    isTerminator: audio.isTerminator)
            markSpeaking(session: session, ended: audio.isTerminator)
        } catch {
            Self.log.error("Audio decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markSpeaking(session: UInt32, ended: Bool) {
        speakingClearTasks[session]?.cancel()
        if ended {
            speakingSessions.remove(session)
            speakingClearTasks[session] = nil
            return
        }
        speakingSessions.insert(session)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.speakingSessions.remove(session)
                self.speakingClearTasks[session] = nil
            }
        }
        speakingClearTasks[session] = task
    }

    // MARK: - Outgoing user actions

    func moveToChannel(_ channelID: UInt32) async {
        guard case .connected = state, let session = sessionID, let transport else { return }
        if users[session]?.channelID == channelID { return }
        let msg = UserStateMessage(session: session, channelID: channelID)
        do {
            try await transport.sendFrame(msg)
            Self.log.info("Requested move to channel \(channelID, privacy: .public)")
        } catch {
            Self.log.error("Failed to send channel move: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called immediately after `ServerSync`: if this connect attempt
    /// originated from a `mumble://host/Channel/Sub` URL, resolve the path
    /// against the now-populated channel tree and request a move.
    private func tryJoinDesiredChannelAfterSync() async {
        guard let path = currentParameters?.desiredChannelPath, !path.isEmpty else { return }
        if let channelID = resolveChannel(path: path) {
            Self.log.info("Auto-joining channel '\(path.joined(separator: "/"), privacy: .public)' (id \(channelID, privacy: .public))")
            await moveToChannel(channelID)
        } else {
            Self.log.notice("Desired channel '\(path.joined(separator: "/"), privacy: .public)' not found on server")
        }
    }

    /// Walk the channel tree from the root, matching segments against
    /// child names case-insensitively. Mirrors the reference client's
    /// `MainWindow::findDesiredChannel` (mumble/src/mumble/MainWindow.cpp:1387):
    /// when a segment doesn't match any child, accumulate it and try
    /// `accumulated/next` as a composite — this lets channel names that
    /// themselves contain '/' resolve without percent-encoding. Returns
    /// `nil` if no segment ever matched.
    func resolveChannel(path: [String]) -> UInt32? {
        guard let rootID = rootChannelID else { return nil }
        return Self.resolveChannel(path: path, in: channels, rootID: rootID)
    }

    /// Pure form of `resolveChannel(path:)` — the actor state is passed
    /// in so unit tests can exercise the matching rules against a
    /// synthetic channel tree without spinning up a transport.
    nonisolated static func resolveChannel(path: [String], in channels: [UInt32: ChannelNode], rootID: UInt32) -> UInt32? {
        var current = rootID
        var pending: String?
        var found = false

        for segment in path {
            let lowered = segment.lowercased()
            if lowered.isEmpty { continue }
            let composite = pending.map { "\($0)/\(lowered)" } ?? lowered
            guard let parent = channels[current] else { break }
            let match = parent.childChannelIDs.first(where: { childID in
                channels[childID]?.name.lowercased() == composite
            })
            if let matchedID = match {
                current = matchedID
                pending = nil
                found = true
            } else {
                pending = composite
            }
        }
        return found ? current : nil
    }

    func setSelfMute(_ muted: Bool) async {
        await sendSelfState(selfMute: muted)
    }

    func setSelfDeaf(_ deafened: Bool) async {
        // Deaf implies mute in Mumble.
        await sendSelfState(selfMute: deafened ? true : nil, selfDeaf: deafened)
    }

    /// Slot 1 is reserved for the configured Whisper/Shout target. We don't
    /// register additional slots in this iteration, so a single ID is enough.
    private static let whisperVoiceTargetID: UInt32 = 1

    /// Configure the per-packet `target` for outgoing voice. Pass a non-nil
    /// `WhisperTarget` to redirect outgoing audio at the slot 1 VoiceTarget;
    /// pass `nil` to revert to normal-channel talk (`target = 0`).
    ///
    /// When non-nil we also send a `VoiceTargetMessage` to register slot 1 on
    /// the server with the resolved channel + flags. The slot stays
    /// registered after release — re-registering on each press is cheap and
    /// keeps state consistent if the channel resolution changed (e.g. user
    /// moved between channels and the binding is `.current`).
    func applyWhisperTarget(_ target: WhisperTarget?) async {
        guard case .connected = state, let transport else {
            outgoingVoiceTarget = 0
            return
        }
        guard let target else {
            outgoingVoiceTarget = 0
            return
        }
        guard let resolvedChannelID = resolveWhisperChannelID(for: target) else {
            Self.log.warning("Whisper target couldn't be resolved (mode=\(String(describing: target.channelMode), privacy: .public)); falling back to normal talk.")
            outgoingVoiceTarget = 0
            return
        }
        let msg = VoiceTargetMessage(
            id: Self.whisperVoiceTargetID,
            targets: [
                VoiceTargetMessage.Target(
                    channelID: resolvedChannelID,
                    group: target.restrictGroup.isEmpty ? nil : target.restrictGroup,
                    includeLinks: target.includeLinks ? true : nil,
                    includeChildren: target.includeChildren ? true : nil
                )
            ]
        )
        do {
            try await transport.sendFrame(msg)
            outgoingVoiceTarget = Self.whisperVoiceTargetID
        } catch {
            Self.log.error("Whisper target register failed: \(error.localizedDescription, privacy: .public)")
            outgoingVoiceTarget = 0
        }
    }

    /// Resolve a `WhisperTarget` to a concrete channel id using the current
    /// channel tree + the local user's location. `nil` means we couldn't
    /// determine a channel (no current user, no root, etc.) and the caller
    /// should fall back to normal talk.
    private func resolveWhisperChannelID(for target: WhisperTarget) -> UInt32? {
        switch target.channelMode {
        case .root:
            return rootChannelID
        case .current:
            guard let session = sessionID else { return nil }
            return users[session]?.channelID
        case .parent:
            guard let session = sessionID,
                  let currentID = users[session]?.channelID,
                  let current = channels[currentID] else { return nil }
            // The root has no parent — if the user is at root, "Parent" is
            // ambiguous; treat it as "current" rather than fail outright.
            return current.parentID ?? currentID
        case .byID:
            return target.channelID
        }
    }

    private func sendSelfState(selfMute: Bool? = nil, selfDeaf: Bool? = nil) async {
        guard case .connected = state, let session = sessionID, let transport else { return }
        let msg = UserStateMessage(session: session, selfMute: selfMute, selfDeaf: selfDeaf)
        do {
            try await transport.sendFrame(msg)
        } catch {
            Self.log.error("Failed to send self-state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Keepalive ping

    private func startPingLoop(transport: MumbleTransport) {
        pingTask = Task { [weak self] in
            var sent: UInt64 = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pingInterval)
                    if Task.isCancelled { return }
                    let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                    let ping = PingMessage(timestamp: timestamp)
                    try await transport.sendFrame(ping)
                    sent &+= 1
                    Self.log.debug("Sent ping #\(sent, privacy: .public) ts=\(timestamp, privacy: .public)")
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
