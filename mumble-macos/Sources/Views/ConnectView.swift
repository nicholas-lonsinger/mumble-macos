import SwiftUI

struct ConnectView: View {
    let onConnect: (ServerConnectionParameters) -> Void
    let onCancel: () -> Void
    /// When the window is opened via a `mumble://` URL, the parsed URL lands
    /// here and overwrites the persisted form values on first appear.
    var prefill: MumbleURL? = nil

    // Host/port/username persist across launches. Password lives in
    // `QuickConnectMemory` for the duration of the session — wiped on quit
    // by design (saved bookmarks use the keychain instead).
    @AppStorage("lastServerHost") private var host = ServerConnectionParameters.defaultPublicTestServer.host
    @AppStorage("lastServerPort") private var port = String(ServerConnectionParameters.defaultPublicTestServer.port)
    @AppStorage("lastServerUsername") private var username = ServerConnectionParameters.defaultPublicTestServer.username
    @State private var quickConnect = QuickConnectMemory.shared
    @State private var identitySummary: StoredIdentitySummary?
    /// The URL's channel path travels with the form silently — there's no
    /// field for it in the UI but it has to survive into `currentParameters`
    /// so the post-`ServerSync` join code in `MumbleClient` can use it.
    @State private var desiredChannelPath: [String] = []

    @State private var saveSheetVisible = false
    @State private var saveDraft = SaveDraft()
    @State private var saveError: String?
    @State private var bookStore = ServerBookStore.shared

    var body: some View {
        @Bindable var quickConnect = quickConnect

        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Mumble Server")
                .font(.headline)

            Form {
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                SecureField("Password", text: $quickConnect.lastPassword)
            }
            .formStyle(.grouped)

            identityIndicator
                .padding(.top, 4)

            HStack {
                Button("Save…") { openSaveSheet() }
                    .disabled(!canSave)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(currentParameters)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            applyPrefillIfNeeded()
            reloadIdentity()
        }
        .sheet(isPresented: $saveSheetVisible) {
            SaveServerSheet(
                draft: $saveDraft,
                groups: bookStore.groups.sorted { $0.sortIndex < $1.sortIndex },
                errorMessage: saveError,
                onCancel: { saveSheetVisible = false },
                onSave: performSave
            )
        }
    }

    private func applyPrefillIfNeeded() {
        guard let prefill else { return }
        host = prefill.host
        port = String(prefill.port)
        if let u = prefill.username { username = u }
        // Explicit password in the URL wins; otherwise leave the cached
        // session-scoped value alone so the user doesn't have to retype it.
        if let urlPassword = prefill.password {
            quickConnect.lastPassword = urlPassword
        }
        desiredChannelPath = prefill.channelPath
    }

    @ViewBuilder
    private var identityIndicator: some View {
        HStack(spacing: 6) {
            if let summary = identitySummary {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Presenting identity: \(summary.commonName)")
                        .font(.caption)
                    Text(summary.sha1Fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                Text("No client certificate — connecting as guest. Import one in ⌘Mumble ▸ Certificate Manager….")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func reloadIdentity() {
        identitySummary = try? IdentityStore.shared.currentSummary()
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Save... is enabled whenever the form has the minimum needed to identify
    /// a server. The password may be empty — saving without one is a valid
    /// pattern (e.g. for guest-friendly servers).
    private var canSave: Bool { canConnect }

    private var currentParameters: ServerConnectionParameters {
        ServerConnectionParameters(
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 64738,
            username: username.trimmingCharacters(in: .whitespaces),
            password: quickConnect.lastPassword,
            desiredChannelPath: desiredChannelPath
        )
    }

    // MARK: - Save…

    private func openSaveSheet() {
        // Default the label to host (matches the reference client's behavior
        // when the user adds a bookmark with no explicit name).
        saveDraft.label = host.trimmingCharacters(in: .whitespaces)
        saveDraft.groupID = bookStore.group(of: .favorites)?.id
        saveDraft.rememberPassword = !quickConnect.lastPassword.isEmpty
        saveError = nil
        saveSheetVisible = true
    }

    private func performSave() {
        let label = saveDraft.label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else {
            saveError = "Display name can't be empty."
            return
        }
        guard let portValue = UInt16(port) else {
            saveError = "Port must be a number 0–65535."
            return
        }

        let server = SavedServer(
            label: label,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            username: username.trimmingCharacters(in: .whitespaces),
            groupID: saveDraft.groupID,
            rememberPassword: saveDraft.rememberPassword
        )
        bookStore.addServer(server)

        if saveDraft.rememberPassword, !quickConnect.lastPassword.isEmpty {
            do {
                try ServerPasswordStore.shared.setPassword(
                    quickConnect.lastPassword,
                    forServer: server.id
                )
            } catch {
                // Roll back the bookmark if we couldn't persist its password —
                // a half-saved entry is more confusing than a clean failure.
                try? bookStore.removeServer(id: server.id)
                saveError = "Couldn't save password to keychain: \(error.localizedDescription)"
                return
            }
        }

        saveSheetVisible = false
    }
}

private struct SaveServerSheet: View {
    @Binding var draft: SaveDraft
    let groups: [ServerGroup]
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Server")
                .font(.headline)

            Form {
                TextField("Display Name", text: $draft.label)
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
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// File-private so `ConnectView` and `SaveServerSheet` can share it.
fileprivate struct SaveDraft {
    var label: String = ""
    var groupID: UUID? = nil
    var rememberPassword: Bool = true
}

#Preview {
    ConnectView(onConnect: { _ in }, onCancel: { })
}
