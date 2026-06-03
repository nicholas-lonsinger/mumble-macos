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
    /// Pre-flattened (channel, depth) list, computed once on appear.
    /// A naïve recursive `@ViewBuilder` over the channel hierarchy ends up
    /// nesting `VStack`s inside the `LazyVStack`, which forces every
    /// channel to instantiate as soon as the root is visible — eats ~600
    /// channels on the benchmark server in one shot. Flattening once and
    /// using a single `ForEach` keeps `LazyVStack` actually lazy.
    @State private var flattenedTree: [WhisperTargetTree.TreeRow] = []

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
        .onAppear { flattenedTree = WhisperTargetTree.flattenTree(channels: channels, rootID: rootChannelID) }
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
                if flattenedTree.isEmpty {
                    Text("Connect to a server to browse channels.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(flattenedTree) { row in
                        channelRow(channelID: row.channelID, name: row.name, depth: row.depth)
                    }
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

    private func channelRow(channelID: UInt32, name: String, depth: Int) -> some View {
        let isSelected = target.channelMode == .byID && target.channelID == channelID
        return HStack {
            Text(name.isEmpty ? "Root" : name)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            target.channelMode = .byID
            target.channelID = channelID
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
