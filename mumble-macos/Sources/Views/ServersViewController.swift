import AppKit

/// Source-list browser for saved Mumble servers.
///
/// Follows macOS Finder/Mail conventions: an "On This Mac" section holds
/// the ungrouped servers, groups expand/collapse via their disclosure
/// chevron, double-click (or Return) on a server connects, right-click
/// exposes the full action set, and Add / Edit / Remove are also
/// reachable via the bar above the list for discoverability.
///
/// NSOutlineView gives us native selection, double-click, and drag &
/// drop — the SwiftUI version needed simultaneous-TapGesture workarounds
/// because `.draggable` rows swallowed the List's selection clicks; all
/// of that dies here.
@MainActor
final class ServersViewController: NSViewController,
                                   NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSMenuDelegate {
    /// Dispatches a connect request with the password already resolved
    /// (from the keychain or a prompt). The window controller routes this
    /// to `MumbleClient` and brings the main window forward.
    private let onConnectRequested: (SavedServer, String) -> Void

    private let bookStore = ServerBookStore.shared
    private var tracker: ObservationTracker?

    private let outlineView = NSOutlineView()
    private var connectButton: NSButton!
    private var editButton: NSButton!
    private var removeButton: NSButton!

    // MARK: - Item identity

    /// Stable boxed items so NSOutlineView keeps expansion/selection
    /// across `reloadData()`. Interned per kind+ID.
    private final class Item: NSObject {
        enum Kind: Hashable {
            case onThisMacSection
            case server(UUID)
            case group(UUID)
            case ungroupHint
        }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? Item)?.kind == kind
        }
        override var hash: Int { kind.hashValue }
    }

    private var itemCache: [Item.Kind: Item] = [:]

    private func item(_ kind: Item.Kind) -> Item {
        if let cached = itemCache[kind] { return cached }
        let fresh = Item(kind)
        itemCache[kind] = fresh
        return fresh
    }

    // Snapshot read by the data source — refreshed per render.
    private var topLevelServers: [SavedServer] = []
    private var groupsSorted: [ServerGroup] = []
    private var serversByGroup: [UUID: [SavedServer]] = [:]

    /// True while render() drives expandItem/collapseItem to mirror
    /// `group.isCollapsed` — those delegate notifications are not user
    /// intent and must not write back to the store.
    private var isApplyingExpansion = false

    init(onConnectRequested: @escaping (SavedServer, String) -> Void) {
        self.onConnectRequested = onConnectRequested
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ServersViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        connectButton = NSButton(title: "Connect", target: self, action: #selector(connectSelected(_:)))
        connectButton.keyEquivalent = "\r"
        editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelected(_:)))
        let addButton = NSButton(image: NSImage(systemSymbolName: "plus",
                                                accessibilityDescription: "Add")!,
                                 target: self, action: #selector(showAddMenu(_:)))
        addButton.isBordered = false
        removeButton = NSButton(image: NSImage(systemSymbolName: "minus",
                                               accessibilityDescription: "Remove")!,
                                target: self, action: #selector(removeSelected(_:)))
        removeButton.isBordered = false
        let barSpacer = NSView()
        barSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [connectButton, editButton, barSpacer, addButton, removeButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let divider = NSBox()
        divider.boxType = .separator

        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick(_:))
        outlineView.registerForDraggedTypes([.mumbleSavedServerPayload, .mumbleServerGroupPayload])

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [bar, divider, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            _ = self.bookStore.groups
            _ = self.bookStore.servers
            self.render()
        }
        tracker?.start()
    }

    // MARK: - Render

    private func render() {
        topLevelServers = bookStore.servers(in: nil)
        groupsSorted = bookStore.topLevelGroupsSorted
        serversByGroup = Dictionary(uniqueKeysWithValues: groupsSorted.map {
            ($0.id, bookStore.servers(in: $0.id))
        })
        // Prune stale interned items so the cache doesn't grow across
        // many add/remove cycles.
        let liveServerIDs = Set(bookStore.servers.map(\.id))
        let liveGroupIDs = Set(groupsSorted.map(\.id))
        itemCache = itemCache.filter { kind, _ in
            switch kind {
            case .server(let id): return liveServerIDs.contains(id)
            case .group(let id): return liveGroupIDs.contains(id)
            case .onThisMacSection, .ungroupHint: return true
            }
        }

        let selectedKind = (outlineView.item(atRow: outlineView.selectedRow) as? Item)?.kind
        outlineView.reloadData()
        applyExpansionState()
        if let selectedKind, let restored = itemCache[selectedKind] {
            let row = outlineView.row(forItem: restored)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        updateBarEnablement()
    }

    private func applyExpansionState() {
        isApplyingExpansion = true
        defer { isApplyingExpansion = false }
        outlineView.expandItem(item(.onThisMacSection))
        for group in groupsSorted {
            let groupItem = item(.group(group.id))
            if group.isCollapsed {
                outlineView.collapseItem(groupItem)
            } else {
                outlineView.expandItem(groupItem)
            }
        }
    }

    // MARK: - Selection helpers

    private var selectedServer: SavedServer? {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
              case .server(let id) = item.kind else { return nil }
        return bookStore.server(id: id)
    }

    private var selectedGroup: ServerGroup? {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
              case .group(let id) = item.kind else { return nil }
        return bookStore.group(id: id)
    }

    private var canRemoveSelection: Bool {
        if selectedServer != nil { return true }
        if let group = selectedGroup, group.kind != .favorites { return true }
        return false
    }

    private func updateBarEnablement() {
        let hasServer = (selectedServer != nil)
        connectButton.isEnabled = hasServer
        editButton.isEnabled = hasServer
        removeButton.isEnabled = canRemoveSelection
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateBarEnablement()
    }

    // MARK: - NSOutlineViewDataSource

    private func children(of item: Any?) -> [Item] {
        guard let item = item as? Item else {
            // Root: the section header, then groups.
            return [self.item(.onThisMacSection)]
                + groupsSorted.map { self.item(.group($0.id)) }
        }
        switch item.kind {
        case .onThisMacSection:
            if topLevelServers.isEmpty {
                // The hint row doubles as a drop target — it's the only
                // way to ungroup a server when there are no other
                // top-level servers to drop onto.
                return [self.item(.ungroupHint)]
            }
            return topLevelServers.map { self.item(.server($0.id)) }
        case .group(let id):
            return (serversByGroup[id] ?? []).map { self.item(.server($0.id)) }
        case .server, .ungroupHint:
            return []
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        switch item.kind {
        case .onThisMacSection, .group: return true
        case .server, .ungroupHint: return false
        }
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Item)?.kind == .onThisMacSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        switch item.kind {
        case .server, .group: return true
        case .onThisMacSection, .ungroupHint: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        // The section header is structural — only groups collapse.
        (item as? Item)?.kind != .onThisMacSection
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        switch item.kind {
        case .onThisMacSection:
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "On This Mac")
            label.font = NSFont.preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabelColor
            embed(label, in: cell)
            return cell

        case .ungroupHint:
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "Drop a server here to ungroup it.")
            label.font = NSFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .tertiaryLabelColor
            embed(label, in: cell)
            return cell

        case .group(let id):
            guard let group = bookStore.group(id: id) else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView(image: NSImage(systemSymbolName: groupSymbol(group),
                                                  accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            let name = NSTextField(labelWithString: group.name)
            name.lineBreakMode = .byTruncatingTail
            let count = NSTextField(labelWithString: "\(serversByGroup[id]?.count ?? 0)")
            count.font = NSFont.preferredFont(forTextStyle: .caption1)
            count.textColor = .secondaryLabelColor
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let stack = NSStackView(views: [icon, name, spacer, count])
            stack.orientation = .horizontal
            stack.spacing = 6
            embed(stack, in: cell)
            return cell

        case .server(let id):
            guard let server = bookStore.server(id: id) else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView(image: NSImage(systemSymbolName: "network",
                                                  accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: server.label)
            label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            let detail = NSTextField(labelWithString: "\(server.host):\(String(server.port))")
            detail.font = NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            let text = NSStackView(views: [label, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let stack = NSStackView(views: [icon, text])
            stack.orientation = .horizontal
            stack.spacing = 8
            embed(stack, in: cell)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .server = (item as? Item)?.kind { return 36 }
        return 24
    }

    private func embed(_ view: NSView, in cell: NSTableCellView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }

    private func groupSymbol(_ group: ServerGroup) -> String {
        switch group.kind {
        case .favorites: "star.fill"
        case .imported: "square.and.arrow.down"
        case .publicMumbleInfo, .publicMumbleCom: "globe"
        case .user: "folder"
        }
    }

    // MARK: - Expansion ↔ store sync

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion(from: notification, isCollapsed: false)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistExpansion(from: notification, isCollapsed: true)
    }

    private func persistExpansion(from notification: Notification, isCollapsed: Bool) {
        guard !isApplyingExpansion else { return }
        guard let item = notification.userInfo?["NSObject"] as? Item else {
            assertionFailure("Expansion notification without an item — userInfo key drift?")
            return
        }
        guard case .group(let id) = item.kind,
              var group = bookStore.group(id: id),
              group.isCollapsed != isCollapsed else { return }
        group.isCollapsed = isCollapsed
        try? bookStore.updateGroup(group)
    }

    // MARK: - Bar actions

    @objc private func connectSelected(_ sender: Any?) {
        guard let server = selectedServer else { return }
        requestConnect(server)
    }

    @objc private func editSelected(_ sender: Any?) {
        guard let server = selectedServer else { return }
        presentEditor(forServerID: server.id)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let newServer = NSMenuItem(title: "New Server",
                                   action: #selector(addServer(_:)), keyEquivalent: "")
        newServer.target = self
        menu.addItem(newServer)
        let newGroup = NSMenuItem(title: "New Group",
                                  action: #selector(addGroup(_:)), keyEquivalent: "")
        newGroup.target = self
        menu.addItem(newGroup)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func addServer(_ sender: Any?) {
        // If a group is selected, default the new server's group to that.
        // Otherwise default to Favorites — the common case where the user
        // just hits + on first launch.
        let initialGroup = selectedGroup?.id ?? bookStore.group(of: .favorites)?.id
        let editor = BookmarkEditorViewController(mode: .add(initialGroupID: initialGroup))
        view.window?.beginSheet(controller: editor, title: "New Server")
    }

    @objc private func addGroup(_ sender: Any?) {
        view.window?.beginSheet(controller: AddGroupViewController(), title: "New Group")
    }

    @objc private func removeSelected(_ sender: Any?) {
        if let server = selectedServer {
            removeServer(server)
        } else if let group = selectedGroup, group.kind != .favorites {
            try? bookStore.removeGroup(id: group.id)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? Item,
              case .server(let id) = item.kind,
              let server = bookStore.server(id: id) else { return }
        requestConnect(server)
    }

    // MARK: - Connect dispatch

    /// Dispatches connect according to the bookmark's `passwordHandling`:
    /// stored → use the keychain value; none required → blank; prompt →
    /// pop the password sheet. A `.useStoredPassword` server with no
    /// keychain entry (recovery path — keychain wiped or write failed
    /// at save) falls through to the prompt rather than failing silently.
    private func requestConnect(_ server: SavedServer) {
        switch server.passwordHandling {
        case .noPasswordRequired:
            onConnectRequested(server, "")
        case .useStoredPassword:
            if let stored = (try? ServerPasswordStore.shared.password(forServer: server.id)) ?? nil {
                onConnectRequested(server, stored)
            } else {
                presentPasswordPrompt(for: server)
            }
        case .promptEveryTime:
            presentPasswordPrompt(for: server)
        }
    }

    private func presentPasswordPrompt(for server: SavedServer) {
        let prompt = PasswordPromptViewController(
            serverLabel: server.label,
            serverDetails: "\(server.host):\(String(server.port)) — \(server.username)",
            onConnect: { [weak self] password in
                self?.onConnectRequested(server, password)
            },
            onCancel: {}
        )
        view.window?.beginSheet(controller: prompt, title: "Password")
    }

    private func presentEditor(forServerID id: SavedServer.ID) {
        let editor = BookmarkEditorViewController(
            mode: .edit(id),
            onConnectAfterSave: { [weak self] server in
                self?.requestConnect(server)
            }
        )
        view.window?.beginSheet(controller: editor, title: "Edit Server")
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
        // Reset sort index so updateServer keeps an explicit value of 0;
        // matches the previous behavior for "Move to Group".
        updated.sortIndex = 0
        try? bookStore.updateServer(updated)
    }

    // MARK: - Context menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? Item else { return }

        switch item.kind {
        case .server(let id):
            guard let server = bookStore.server(id: id) else { return }
            menu.addItem(makeItem("Connect") { [weak self] in self?.requestConnect(server) })
            menu.addItem(makeItem("Edit…") { [weak self] in self?.presentEditor(forServerID: id) })
            menu.addItem(.separator())
            let moveMenu = NSMenu()
            let topLevel = makeItem("Top Level") { [weak self] in self?.moveServer(server, to: nil) }
            moveMenu.addItem(topLevel)
            for group in groupsSorted {
                let entry = makeItem(group.name) { [weak self] in
                    self?.moveServer(server, to: group.id)
                }
                if server.groupID == group.id { entry.isEnabled = false }
                moveMenu.addItem(entry)
            }
            let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            move.submenu = moveMenu
            menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(makeItem("Remove") { [weak self] in self?.removeServer(server) })

        case .group(let id):
            guard let group = bookStore.group(id: id) else { return }
            let rename = makeItem("Rename…") { [weak self] in self?.promptRename(group) }
            rename.isEnabled = (group.kind != .favorites)
            menu.addItem(rename)
            if group.kind == .favorites {
                let caption = NSMenuItem(title: "The Favorites group can't be removed.",
                                         action: nil, keyEquivalent: "")
                caption.isEnabled = false
                menu.addItem(caption)
            } else {
                menu.addItem(makeItem("Remove") { [weak self] in
                    try? self?.bookStore.removeGroup(id: id)
                })
            }

        case .onThisMacSection, .ungroupHint:
            break
        }
    }

    /// Closure-backed menu item. NSMenuItem wants target/action; a tiny
    /// trampoline keeps the menu construction readable.
    private func makeItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuHandler(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuHandler(handler)
        return item
    }

    private final class MenuHandler {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuHandler(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuHandler)?.run()
    }

    // MARK: - Rename

    private func promptRename(_ group: ServerGroup) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "Enter a new name for the group."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = group.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != group.name else { return }
            var renamed = group
            renamed.name = trimmed
            try? self?.bookStore.updateGroup(renamed)
        }
    }

    // MARK: - Drag & drop

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? Item else { return nil }
        let pbItem = NSPasteboardItem()
        switch item.kind {
        case .server(let id):
            pbItem.setString(id.uuidString, forType: .mumbleSavedServerPayload)
        case .group(let id):
            pbItem.setString(id.uuidString, forType: .mumbleServerGroupPayload)
        case .onThisMacSection, .ungroupHint:
            return nil
        }
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Intra-app only — these payloads mean nothing to other apps and
        // shouldn't be offered to them.
        context == .withinApplication ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard

        if pasteboard.string(forType: .mumbleSavedServerPayload) != nil {
            guard let target = item as? Item else { return [] }
            switch target.kind {
            case .server, .group, .ungroupHint:
                // All server-payload drops are drop-ON semantics; normalize
                // between-rows proposals onto the row itself.
                outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            case .onThisMacSection:
                return []
            }
        }

        if pasteboard.string(forType: .mumbleServerGroupPayload) != nil {
            guard let target = item as? Item, case .group = target.kind else { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        return []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let target = item as? Item else { return false }
        let pasteboard = info.draggingPasteboard

        if let raw = pasteboard.string(forType: .mumbleSavedServerPayload),
           let draggedID = UUID(uuidString: raw) {
            switch target.kind {
            case .group(let groupID):
                // Into the group, at the end.
                let last = serversByGroup[groupID]?.last?.id
                try? bookStore.moveServer(draggedID, toGroup: groupID, afterServerID: last)
                return true
            case .server(let targetID):
                guard draggedID != targetID,
                      let targetServer = bookStore.server(id: targetID) else { return false }
                // Place immediately after the target row, in its group.
                try? bookStore.moveServer(draggedID,
                                          toGroup: targetServer.groupID,
                                          afterServerID: targetID)
                return true
            case .ungroupHint:
                try? bookStore.moveServer(draggedID, toGroup: nil, afterServerID: nil)
                return true
            case .onThisMacSection:
                return false
            }
        }

        if let raw = pasteboard.string(forType: .mumbleServerGroupPayload),
           let draggedID = UUID(uuidString: raw) {
            guard case .group(let targetID) = target.kind, draggedID != targetID else {
                return false
            }
            try? bookStore.moveGroup(draggedID, afterGroupID: targetID)
            return true
        }

        return false
    }
}
