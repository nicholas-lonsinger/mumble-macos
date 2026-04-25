import SwiftUI

/// Identifier for whatever the user has selected in the source list. Used as
/// the `List`'s selection binding type.
enum ServersSelection: Hashable {
    case server(UUID)
    case group(UUID)
}

/// Source-list browser for saved Mumble servers.
///
/// Follows macOS Finder/Mail conventions: groups expand/collapse via a
/// chevron, double-click on a server connects, ⏎ connects the selected
/// server, right-click exposes the full action set. Add / Edit / Remove
/// are also reachable via toolbar buttons for discoverability.
struct ServersView: View {
    @State private var bookStore = ServerBookStore.shared
    @State private var publicRefresh = PublicServerRefresh.shared
    /// Dispatches a connect request with the password already resolved (from
    /// the keychain or a prompt). The controller routes this to
    /// `MumbleClient` and brings the main window forward.
    let onConnectRequested: (SavedServer, String) -> Void

    @AppStorage("lastServerUsername") private var defaultUsername = ServerConnectionParameters.defaultPublicTestServer.username

    @State private var selection: ServersSelection?
    @State private var sheet: ActiveSheet?
    @State private var renameTarget: ServerGroup?
    @State private var renameDraft: String = ""
    @State private var pendingPasswordPrompt: PendingPrompt?

    /// Pairs a server with the in-progress password the user is typing.
    /// Held outside `ActiveSheet` because it has its own `@State` lifecycle
    /// — typing into the SecureField shouldn't recreate the sheet.
    private struct PendingPrompt: Identifiable {
        let server: SavedServer
        var password: String = ""
        var id: UUID { server.id }
    }

    /// SwiftUI `.sheet(item:)` requires `Identifiable`. Wrapping our state in
    /// a single enum keeps the view from juggling multiple `Bool` flags.
    private enum ActiveSheet: Identifiable {
        case addServer(groupID: UUID?)
        case editServer(SavedServer.ID)
        case addGroup

        var id: String {
            switch self {
            case .addServer(let g): "add-\(g?.uuidString ?? "top")"
            case .editServer(let s): "edit-\(s.uuidString)"
            case .addGroup: "add-group"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
            Divider()
            sourceList
        }
        .sheet(item: $sheet) { active in
            sheetContent(for: active)
        }
        .sheet(item: $pendingPasswordPrompt) { prompt in
            PasswordPromptView(
                serverLabel: prompt.server.label,
                serverDetails: "\(prompt.server.host):\(prompt.server.port) — \(prompt.server.username)",
                password: Binding(
                    get: { pendingPasswordPrompt?.password ?? "" },
                    set: { pendingPasswordPrompt?.password = $0 }
                ),
                onConnect: {
                    let typed = pendingPasswordPrompt?.password ?? ""
                    let server = prompt.server
                    pendingPasswordPrompt = nil
                    onConnectRequested(server, typed)
                },
                onCancel: { pendingPasswordPrompt = nil }
            )
        }
        .alert("Rename Group",
               isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
               )) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        } message: {
            Text("Enter a new name for the group.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Connect") { connectSelected() }
                .disabled(selectedServer == nil)
                .keyboardShortcut(.defaultAction)
            Button("Edit…") { editSelected() }
                .disabled(selectedServer == nil)
            Spacer()
            refreshPublicButton
            Menu {
                Button("New Server") { addServer() }
                Button("New Group") { sheet = .addGroup }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus")
            }
            .disabled(!canRemoveSelection)
        }
    }

    /// "Refresh Public Servers" button. Disabled while a fetch is in flight;
    /// post-completion shows a small label to the right with the count or
    /// the error message until the user triggers the next refresh.
    @ViewBuilder
    private var refreshPublicButton: some View {
        HStack(spacing: 6) {
            switch publicRefresh.status {
            case .running:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            case .finished(let n):
                Text("Imported \(n)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            case .idle:
                EmptyView()
            }
            Button {
                publicRefresh.start(defaultUsername: defaultUsername)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Refresh Public Servers from publist.mumble.info")
            .disabled(publicRefresh.status == .running)
        }
    }

    // MARK: - Source list

    private var sourceList: some View {
        List(selection: $selection) {
            // Ungrouped (top-level) servers appear first, in their own
            // implicit "On My Mac"-style section. When the section is
            // empty we render a hint row that doubles as a drop target
            // — that's the only way to ungroup a server when there are
            // no other top-level servers to drop onto.
            Section("On This Mac") {
                ForEach(bookStore.servers(in: nil)) { server in
                    serverRow(server)
                }
                if bookStore.servers(in: nil).isEmpty {
                    ungroupDropHint
                }
            }

            ForEach(bookStore.topLevelGroupsSorted) { group in
                groupSection(group)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var ungroupDropHint: some View {
        Text("Drop a server here to ungroup it.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: SavedServerPayload.self) { items, _ in
                guard let payload = items.first else { return false }
                try? bookStore.moveServer(payload.id, toGroup: nil, afterServerID: nil)
                return true
            }
    }

    @ViewBuilder
    private func groupSection(_ group: ServerGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !group.isCollapsed },
                set: { expanded in
                    var g = group
                    g.isCollapsed = !expanded
                    try? bookStore.updateGroup(g)
                }
            )
        ) {
            ForEach(bookStore.servers(in: group.id)) { server in
                serverRow(server)
            }
        } label: {
            groupRowLabel(group)
        }
        .tag(ServersSelection.group(group.id))
    }

    @ViewBuilder
    private func groupRowLabel(_ group: ServerGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: groupIcon(group))
                .foregroundStyle(.secondary)
            Text(group.name)
            Spacer()
            Text("\(bookStore.servers(in: group.id).count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .draggable(ServerGroupPayload(id: group.id))
        // Server payload → moves the server into this group at the end.
        // Group payload → reorders this group after the dragged group.
        .dropDestination(for: SavedServerPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            let last = bookStore.servers(in: group.id).last?.id
            try? bookStore.moveServer(payload.id, toGroup: group.id, afterServerID: last)
            return true
        }
        .dropDestination(for: ServerGroupPayload.self) { items, _ in
            guard let payload = items.first, payload.id != group.id else { return false }
            try? bookStore.moveGroup(payload.id, afterGroupID: group.id)
            return true
        }
        .contextMenu {
            Button("Rename…") { startRenaming(group) }
                .disabled(group.kind == .favorites)
            if group.kind == .favorites {
                Text("The Favorites group can't be removed.")
            } else {
                Button("Remove", role: .destructive) {
                    try? bookStore.removeGroup(id: group.id)
                }
            }
        }
    }

    private func groupIcon(_ group: ServerGroup) -> String {
        switch group.kind {
        case .favorites: "star.fill"
        case .imported: "square.and.arrow.down"
        case .publicMumbleInfo, .publicMumbleCom: "globe"
        case .user: "folder"
        }
    }

    @ViewBuilder
    private func serverRow(_ server: SavedServer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.label)
                    .fontWeight(.medium)
                Text("\(server.host):\(server.port)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            requestConnect(server)
        }
        .draggable(SavedServerPayload(id: server.id))
        // Drop a server onto this row → place dropped server immediately
        // after this one, in this row's group.
        .dropDestination(for: SavedServerPayload.self) { items, _ in
            guard let payload = items.first, payload.id != server.id else { return false }
            try? bookStore.moveServer(payload.id, toGroup: server.groupID, afterServerID: server.id)
            return true
        }
        .contextMenu {
            Button("Connect") { requestConnect(server) }
            Button("Edit…") { sheet = .editServer(server.id) }
            Divider()
            Menu("Move to Group") {
                Button("Top Level") { moveServer(server, to: nil) }
                ForEach(bookStore.groups.sorted(by: { $0.sortIndex < $1.sortIndex })) { group in
                    Button(group.name) { moveServer(server, to: group.id) }
                        .disabled(server.groupID == group.id)
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                removeServer(server)
            }
        }
        .tag(ServersSelection.server(server.id))
    }

    // MARK: - Selection helpers

    private var selectedServer: SavedServer? {
        if case .server(let id) = selection { return bookStore.server(id: id) }
        return nil
    }

    private var selectedGroup: ServerGroup? {
        if case .group(let id) = selection { return bookStore.group(id: id) }
        return nil
    }

    private var canRemoveSelection: Bool {
        if let _ = selectedServer { return true }
        if let group = selectedGroup, group.kind != .favorites { return true }
        return false
    }

    // MARK: - Actions

    private func connectSelected() {
        guard let server = selectedServer else { return }
        requestConnect(server)
    }

    /// Resolves a stored password if one exists; otherwise hands off to the
    /// password-prompt sheet. A keychain read failure is treated as
    /// "no password" — better than refusing to connect.
    private func requestConnect(_ server: SavedServer) {
        if server.rememberPassword,
           let stored = (try? ServerPasswordStore.shared.password(forServer: server.id)) ?? nil {
            onConnectRequested(server, stored)
            return
        }
        pendingPasswordPrompt = PendingPrompt(server: server)
    }

    private func editSelected() {
        guard let server = selectedServer else { return }
        sheet = .editServer(server.id)
    }

    private func addServer() {
        // If a group is selected, default the new server's group to that.
        // Otherwise default to Favorites — the spec'd behavior for the
        // common case where the user just hits + on first launch.
        let initialGroup: UUID? = {
            if let group = selectedGroup { return group.id }
            return bookStore.group(of: .favorites)?.id
        }()
        sheet = .addServer(groupID: initialGroup)
    }

    private func removeSelected() {
        if let server = selectedServer {
            removeServer(server)
        } else if let group = selectedGroup, group.kind != .favorites {
            try? bookStore.removeGroup(id: group.id)
        }
    }

    private func removeServer(_ server: SavedServer) {
        // Drop any keychain password we owned for it. Best-effort: a stale
        // keychain entry is not catastrophic but cleanup keeps things tidy.
        try? ServerPasswordStore.shared.deletePassword(forServer: server.id)
        try? bookStore.removeServer(id: server.id)
    }

    private func moveServer(_ server: SavedServer, to groupID: UUID?) {
        var updated = server
        updated.groupID = groupID
        // Reset sort index so it lands at the end of the destination group;
        // ServerBookStore.updateServer keeps the explicit value the caller
        // passes in, so we set 0 here only if we actually want auto-place.
        updated.sortIndex = 0
        try? bookStore.updateServer(updated)
    }

    private func startRenaming(_ group: ServerGroup) {
        renameDraft = group.name
        renameTarget = group
    }

    private func commitRename() {
        guard var group = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != group.name {
            group.name = trimmed
            try? bookStore.updateGroup(group)
        }
        renameTarget = nil
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(for active: ActiveSheet) -> some View {
        switch active {
        case .addServer(let groupID):
            AddServerSheet(
                bookStore: bookStore,
                initialGroupID: groupID,
                onClose: { sheet = nil }
            )
        case .editServer(let id):
            EditServerSheet(
                bookStore: bookStore,
                serverID: id,
                onClose: { sheet = nil },
                onConnectAfterSave: { server in
                    sheet = nil
                    requestConnect(server)
                }
            )
        case .addGroup:
            AddGroupSheet(
                bookStore: bookStore,
                onClose: { sheet = nil }
            )
        }
    }
}

// MARK: - Sheet wrappers

/// Each sheet wrapper owns its own `@State` draft so cancel cleanly drops it.
/// Doing this inline in `ServersView` would leak the draft state across
/// presentations and require manual reset on every sheet close.
private struct AddServerSheet: View {
    let bookStore: ServerBookStore
    let initialGroupID: UUID?
    let onClose: () -> Void

    @State private var draft: BookmarkEditorDraft
    @State private var errorMessage: String?

    init(bookStore: ServerBookStore, initialGroupID: UUID?, onClose: @escaping () -> Void) {
        self.bookStore = bookStore
        self.initialGroupID = initialGroupID
        self.onClose = onClose
        _draft = State(initialValue: BookmarkEditorDraft.empty(initialGroupID: initialGroupID))
    }

    var body: some View {
        BookmarkEditorView(
            mode: .add,
            groups: bookStore.groups.sorted { $0.sortIndex < $1.sortIndex },
            draft: $draft,
            errorMessage: errorMessage,
            onSave: save,
            onSaveAndConnect: nil,
            onCancel: onClose
        )
    }

    private func save() {
        guard let port = UInt16(draft.port) else {
            errorMessage = "Port must be 0–65535."
            return
        }
        let server = SavedServer(
            label: draft.label.trimmingCharacters(in: .whitespaces),
            host: draft.host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: draft.username.trimmingCharacters(in: .whitespaces),
            groupID: draft.groupID,
            rememberPassword: draft.rememberPassword
        )
        bookStore.addServer(server)
        if draft.rememberPassword, !draft.password.isEmpty {
            do {
                try ServerPasswordStore.shared.setPassword(draft.password, forServer: server.id)
            } catch {
                try? bookStore.removeServer(id: server.id)
                errorMessage = "Couldn't save password: \(error.localizedDescription)"
                return
            }
        }
        onClose()
    }
}

private struct EditServerSheet: View {
    let bookStore: ServerBookStore
    let serverID: SavedServer.ID
    let onClose: () -> Void
    let onConnectAfterSave: (SavedServer) -> Void

    @State private var draft: BookmarkEditorDraft
    @State private var errorMessage: String?
    @State private var loadFailed = false

    init(bookStore: ServerBookStore,
         serverID: SavedServer.ID,
         onClose: @escaping () -> Void,
         onConnectAfterSave: @escaping (SavedServer) -> Void) {
        self.bookStore = bookStore
        self.serverID = serverID
        self.onClose = onClose
        self.onConnectAfterSave = onConnectAfterSave
        if let server = bookStore.server(id: serverID) {
            let pw = (try? ServerPasswordStore.shared.password(forServer: serverID)) ?? nil
            _draft = State(initialValue: BookmarkEditorDraft.from(server, currentPassword: pw))
        } else {
            _draft = State(initialValue: BookmarkEditorDraft.empty())
            _loadFailed = State(initialValue: true)
        }
    }

    var body: some View {
        BookmarkEditorView(
            mode: .edit(serverID),
            groups: bookStore.groups.sorted { $0.sortIndex < $1.sortIndex },
            draft: $draft,
            errorMessage: errorMessage ?? (loadFailed ? "Server no longer exists." : nil),
            onSave: { save(thenConnect: false) },
            onSaveAndConnect: { save(thenConnect: true) },
            onCancel: onClose
        )
    }

    private func save(thenConnect: Bool) {
        guard !loadFailed else { onClose(); return }
        guard let port = UInt16(draft.port) else {
            errorMessage = "Port must be 0–65535."
            return
        }
        guard var server = bookStore.server(id: serverID) else {
            errorMessage = "Server no longer exists."
            return
        }
        server.label = draft.label.trimmingCharacters(in: .whitespaces)
        server.host = draft.host.trimmingCharacters(in: .whitespaces)
        server.port = port
        server.username = draft.username.trimmingCharacters(in: .whitespaces)
        server.groupID = draft.groupID
        server.rememberPassword = draft.rememberPassword
        do {
            try bookStore.updateServer(server)
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            return
        }

        // Password handling has three branches: forget, store, no-op.
        do {
            if !draft.rememberPassword {
                try ServerPasswordStore.shared.deletePassword(forServer: serverID)
            } else if draft.password != draft.initialPassword {
                if draft.password.isEmpty {
                    try ServerPasswordStore.shared.deletePassword(forServer: serverID)
                } else {
                    try ServerPasswordStore.shared.setPassword(draft.password, forServer: serverID)
                }
            }
        } catch {
            errorMessage = "Couldn't update password: \(error.localizedDescription)"
            return
        }

        if thenConnect {
            onConnectAfterSave(server)
        } else {
            onClose()
        }
    }
}

private struct AddGroupSheet: View {
    let bookStore: ServerBookStore
    let onClose: () -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        bookStore.addGroup(ServerGroup(name: trimmed, kind: .user))
        onClose()
    }
}
