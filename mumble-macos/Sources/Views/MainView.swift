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
                if client.channels.isEmpty {
                    Text(placeholderSidebarText)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(sortedChannels) { channel in
                        ChannelRowView(channel: channel, usersByID: client.users)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBannerView(state: client.state)
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

    private var sortedChannels: [ChannelNode] {
        client.channels.values.sorted { lhs, rhs in
            if lhs.position != rhs.position {
                return lhs.position < rhs.position
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
        case .disconnected: "Use ⌘N to connect."
        case .connecting, .handshaking: "Loading channels…"
        case .connected: "No channels yet."
        case .failed: "Connection failed."
        }
    }

    private var detailPlaceholderText: String {
        switch client.state {
        case .disconnected: "Not connected. File ▸ Connect to Server… (⌘N)"
        case .connecting: "Opening TLS connection…"
        case .handshaking: "Negotiating Mumble protocol…"
        case .connected: "Connected."
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

private struct ChannelRowView: View {
    let channel: ChannelNode
    let usersByID: [UInt32: UserNode]

    var body: some View {
        DisclosureGroup {
            ForEach(channelUsers) { user in
                Label(user.name, systemImage: userIcon(user))
                    .labelStyle(.titleAndIcon)
            }
        } label: {
            Label(channel.name, systemImage: "number")
        }
    }

    private var channelUsers: [UserNode] {
        channel.userSessionIDs.compactMap { usersByID[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func userIcon(_ user: UserNode) -> String {
        if user.isDeafened || user.isSelfDeafened { return "ear.trianglebadge.exclamationmark" }
        if user.isMuted || user.isSelfMuted { return "mic.slash" }
        return "person"
    }
}

private struct StatusBannerView: View {
    let state: MumbleClient.ConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.callout)
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
