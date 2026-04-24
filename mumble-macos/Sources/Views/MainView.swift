import SwiftUI

struct MainView: View {
    @Environment(MumbleClient.self) private var client

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(titleText)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Channels")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            List {
                if case .connected = client.state,
                   let rootID = client.rootChannelID,
                   let root = client.channels[rootID] {
                    // Only build the tree once the initial sync is done. The
                    // server streams 700+ ChannelState/UserState messages
                    // between TLS and ServerSync; rendering during that burst
                    // would diff the whole tree on every message.
                    ChannelRowView(
                        channel: root,
                        allChannels: client.channels,
                        usersByID: client.users,
                        ownSessionID: client.sessionID,
                        speakingSessions: client.speakingSessions,
                        isTransmitting: client.isTransmitting,
                        onSelectChannel: { id in
                            Task { await client.moveToChannel(id) }
                        }
                    )
                } else {
                    Text(placeholderSidebarText)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .listStyle(.sidebar)
            if let version = client.serverVersion {
                Divider()
                Text("Server \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 240)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBannerView(
                state: client.state,
                serverVersion: client.serverVersion,
                isTransmitting: client.isTransmitting,
                voiceAvailable: client.voiceAvailable
            )
            if !client.serverWelcomeText.isEmpty {
                ScrollView {
                    Text(client.serverWelcomeText)
                        .textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Spacer()
                Text(detailPlaceholderText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var titleText: String {
        switch client.state {
        case .disconnected: "Mumble"
        case .connecting: "Connecting…"
        case .handshaking: "Authenticating…"
        case .connected: "Mumble"
        case .failed: "Mumble — disconnected"
        }
    }

    private var placeholderSidebarText: String {
        switch client.state {
        case .disconnected: "Use ⌘K to connect."
        case .connecting, .handshaking: "Loading channels…"
        case .connected: "No channels yet."
        case .failed: "Connection failed."
        }
    }

    private var detailPlaceholderText: String {
        switch client.state {
        case .disconnected: "Not connected. File ▸ Connect to Server… (⌘K)"
        case .connecting: "Opening TLS connection…"
        case .handshaking: "Negotiating Mumble protocol…"
        case .connected: "Connected."
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

private struct ChannelRowView: View {
    let channel: ChannelNode
    let allChannels: [UInt32: ChannelNode]
    let usersByID: [UInt32: UserNode]
    let ownSessionID: UInt32?
    let speakingSessions: Set<UInt32>
    let isTransmitting: Bool
    let onSelectChannel: (UInt32) -> Void

    /// Nil while the row follows live occupancy. A user toggle latches this
    /// to true/false and from then on the row ignores occupancy changes.
    @State private var userOverride: Bool?

    private var effectiveIsExpanded: Bool {
        userOverride ?? Self.subtreeHasOccupants(of: channel, in: allChannels)
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { effectiveIsExpanded },
            set: { userOverride = $0 }
        )) {
            ForEach(sortedUsers) { user in
                UserRowView(
                    user: user,
                    isOwn: user.id == ownSessionID,
                    isSpeaking: isUserSpeaking(user)
                )
            }
            ForEach(sortedChildren) { child in
                ChannelRowView(
                    channel: child,
                    allChannels: allChannels,
                    usersByID: usersByID,
                    ownSessionID: ownSessionID,
                    speakingSessions: speakingSessions,
                    isTransmitting: isTransmitting,
                    onSelectChannel: onSelectChannel
                )
            }
        } label: {
            Button {
                onSelectChannel(channel.id)
            } label: {
                Label {
                    Text(channel.name.isEmpty ? "(unnamed)" : channel.name)
                } icon: {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var sortedUsers: [UserNode] {
        channel.userSessionIDs
            .compactMap { usersByID[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isUserSpeaking(_ user: UserNode) -> Bool {
        if user.id == ownSessionID { return isTransmitting }
        return speakingSessions.contains(user.id)
    }

    /// A channel is expanded by default iff it — or anything below it — has
    /// users. Keeps the sidebar scannable on huge servers by folding empty
    /// branches. Only consulted at first appearance; @State persists after.
    private static func subtreeHasOccupants(of node: ChannelNode,
                                            in allChannels: [UInt32: ChannelNode]) -> Bool {
        if !node.userSessionIDs.isEmpty { return true }
        for childID in node.childChannelIDs {
            if let child = allChannels[childID],
               subtreeHasOccupants(of: child, in: allChannels) {
                return true
            }
        }
        return false
    }

    private var sortedChildren: [ChannelNode] {
        channel.childChannelIDs
            .compactMap { allChannels[$0] }
            .sorted { lhs, rhs in
                if lhs.position != rhs.position {
                    return lhs.position < rhs.position
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct UserRowView: View {
    let user: UserNode
    let isOwn: Bool
    let isSpeaking: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: primaryIcon)
                .foregroundStyle(iconColor)
            Text(user.name)
                .fontWeight(isOwn ? .semibold : .regular)
            Spacer(minLength: 0)
            if user.isRecording {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
            if user.isPrioritySpeaker {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if user.isMuted || user.isSelfMuted {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.secondary)
            }
            if user.isDeafened || user.isSelfDeafened {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var primaryIcon: String {
        if isSpeaking { return "waveform" }
        return isOwn ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
    }

    private var iconColor: Color {
        if isSpeaking { return .green }
        return isOwn ? .accentColor : .primary
    }
}

private struct StatusBannerView: View {
    let state: MumbleClient.ConnectionState
    let serverVersion: String?
    let isTransmitting: Bool
    let voiceAvailable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.callout)
            if let serverVersion, case .connected = state {
                Text("· server \(serverVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if case .connected = state {
                if voiceAvailable {
                    HStack(spacing: 4) {
                        Image(systemName: isTransmitting ? "mic.fill" : "mic")
                            .foregroundStyle(isTransmitting ? .green : .secondary)
                        Text(isTransmitting ? "Transmitting" : "Hold 🌐+⌃ to talk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Voice unavailable", systemImage: "mic.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .disconnected: .gray
        case .connecting, .handshaking: .yellow
        case .connected: .green
        case .failed: .red
        }
    }

    private var label: String {
        switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .handshaking: "Handshaking"
        case .connected: "Connected"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
