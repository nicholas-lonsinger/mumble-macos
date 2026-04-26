import SwiftUI

/// Modal sheet for editing a Whisper/Shout binding's target. Channel mode
/// only for MVP — user-list mode is deferred. Mirrors the layout of the
/// reference Mumble client's "Whisper Target" dialog (Image #3).
struct WhisperTargetSheet: View {
    let initial: WhisperTarget
    let channels: [UInt32: ChannelNode]
    let rootChannelID: UInt32?
    let onSave: (WhisperTarget) -> Void
    let onCancel: () -> Void

    @State private var target: WhisperTarget

    init(initial: WhisperTarget,
         channels: [UInt32: ChannelNode],
         rootChannelID: UInt32?,
         onSave: @escaping (WhisperTarget) -> Void,
         onCancel: @escaping (() -> Void)) {
        self.initial = initial
        self.channels = channels
        self.rootChannelID = rootChannelID
        self.onSave = onSave
        self.onCancel = onCancel
        _target = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper Target")
                .font(.title3)

            HStack {
                Text("Shout/Whisper to:")
                Picker("", selection: .constant("Channel")) {
                    Text("Channel").tag("Channel")
                }
                .labelsHidden()
                .frame(width: 160)
                .help("Only Channel-mode targets are available in this version.")
            }

            GroupBox(label: Text("Channel Target")) {
                channelPicker
                    .frame(minHeight: 200, idealHeight: 240)
            }

            HStack {
                Text("Restrict to Group")
                TextField("", text: $target.restrictGroup)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 16) {
                Toggle("Shout to Linked channels", isOn: $target.includeLinks)
                Toggle("Shout to subchannels", isOn: $target.includeChildren)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    // MARK: - Channel picker

    @ViewBuilder
    private var channelPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                specialRow(label: "Current", mode: .current)
                specialRow(label: "Root", mode: .root)
                specialRow(label: "Parent", mode: .parent)
                Divider().padding(.vertical, 4)
                if let rootID = rootChannelID {
                    channelTreeRows(channelID: rootID, depth: 0)
                } else {
                    Text("Connect to a server to browse channels.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func specialRow(label: String, mode: WhisperTarget.ChannelMode) -> some View {
        let isSelected = target.channelMode == mode
        return HStack {
            Text(label)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            target.channelMode = mode
            target.channelID = nil
        }
    }

    /// `AnyView` because the function is self-recursive and `some View`
    /// can't be defined in terms of itself.
    private func channelTreeRows(channelID: UInt32, depth: Int) -> AnyView {
        guard let channel = channels[channelID] else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                channelRow(channel, depth: depth)
                ForEach(sortedChildIDs(of: channel), id: \.self) { childID in
                    channelTreeRows(channelID: childID, depth: depth + 1)
                }
            }
        )
    }

    private func channelRow(_ channel: ChannelNode, depth: Int) -> some View {
        let isSelected = target.channelMode == .byID && target.channelID == channel.id
        return HStack {
            Text(channel.name.isEmpty ? "Root" : channel.name)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            target.channelMode = .byID
            target.channelID = channel.id
        }
    }

    private func sortedChildIDs(of channel: ChannelNode) -> [UInt32] {
        // Match MainView ordering: by `position`, then alphabetically by name.
        channel.childChannelIDs.sorted { lhs, rhs in
            let l = channels[lhs]
            let r = channels[rhs]
            let lp = l?.position ?? 0
            let rp = r?.position ?? 0
            if lp != rp { return lp < rp }
            return (l?.name ?? "") < (r?.name ?? "")
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        switch target.channelMode {
        case .current, .root, .parent: return true
        case .byID: return target.channelID != nil
        }
    }
}
