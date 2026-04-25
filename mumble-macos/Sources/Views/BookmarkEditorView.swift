import SwiftUI

/// Working draft used by the bookmark editor. Strings (instead of typed
/// values) for `port` so we can validate the field as the user types
/// without losing partial input.
struct BookmarkEditorDraft: Equatable {
    var label: String = ""
    var host: String = ""
    var port: String = "64738"
    var username: String = ""
    var password: String = ""
    var groupID: UUID? = nil
    var rememberPassword: Bool = true

    /// The "before" snapshot for an edit, so callers can detect whether the
    /// password actually changed and avoid a pointless keychain write.
    var initialPassword: String = ""

    static func empty(initialGroupID: UUID? = nil) -> BookmarkEditorDraft {
        BookmarkEditorDraft(
            label: "",
            host: "",
            port: "64738",
            username: "",
            password: "",
            groupID: initialGroupID,
            rememberPassword: true,
            initialPassword: ""
        )
    }

    static func from(_ server: SavedServer, currentPassword: String?) -> BookmarkEditorDraft {
        BookmarkEditorDraft(
            label: server.label,
            host: server.host,
            port: String(server.port),
            username: server.username,
            password: currentPassword ?? "",
            groupID: server.groupID,
            rememberPassword: server.rememberPassword,
            initialPassword: currentPassword ?? ""
        )
    }
}

enum BookmarkEditorMode: Equatable {
    case add
    case edit(SavedServer.ID)
}

struct BookmarkEditorView: View {
    let mode: BookmarkEditorMode
    let groups: [ServerGroup]
    @Binding var draft: BookmarkEditorDraft
    /// Optional warning surfaced by the controller (e.g. keychain failure).
    let errorMessage: String?
    let onSave: () -> Void
    /// `Save & Connect` only appears when the controller wires it up. The
    /// quick-connect-then-save path uses the Connect button on the Connect
    /// sheet; the bookmark editor's secondary action exists so editing a
    /// bookmark and connecting in one step doesn't need two round-trips.
    let onSaveAndConnect: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Form {
                TextField("Display Name", text: $draft.label)
                TextField("Host", text: $draft.host)
                TextField("Port", text: $draft.port)
                TextField("Username", text: $draft.username)
                SecureField("Password", text: $draft.password)
                Picker("Group", selection: $draft.groupID) {
                    Text("Top Level").tag(UUID?.none)
                    ForEach(groups) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }
                Toggle("Remember password in keychain", isOn: $draft.rememberPassword)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if let onSaveAndConnect {
                    Button("Save & Connect", action: onSaveAndConnect)
                        .disabled(!canSave)
                }
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var title: String {
        switch mode {
        case .add: "New Server"
        case .edit: "Edit Server"
        }
    }

    private var canSave: Bool {
        !draft.label.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(draft.port) != nil
            && !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

#Preview {
    BookmarkEditorView(
        mode: .add,
        groups: [ServerGroup(name: "Favorites", kind: .favorites)],
        draft: .constant(BookmarkEditorDraft.empty()),
        errorMessage: nil,
        onSave: {},
        onSaveAndConnect: nil,
        onCancel: {}
    )
}
