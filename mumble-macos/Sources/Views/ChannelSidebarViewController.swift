import AppKit

/// Sidebar of the main window: the channel/user tree, with a header, a
/// per-state placeholder while not connected, and a server-version footer.
///
/// PERFORMANCE INVARIANT (CLAUDE.md): the tree renders only when
/// `client.state == .connected`. The tracker's render reads
/// `client.channels`/`client.users` exclusively behind that gate, so the
/// 700+ ChannelState/UserState mutations a large server streams between
/// TLS and ServerSync register zero tracked reads here — the tree
/// materializes exactly once, on the ServerSync transition. Benchmark:
/// mumble.sh1t.space (~616 channels) must stay at ~1s handshake.
@MainActor
final class ChannelSidebarViewController: NSViewController,
                                          NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let client: MumbleClient
    private var tracker: ObservationTracker?

    private let outlineView = NSOutlineView()
    private var scrollView: NSScrollView!
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let footerStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")

    // MARK: - Snapshot (read by the data source; refreshed per render)

    private var channelsSnapshot: [UInt32: ChannelNode] = [:]
    private var usersSnapshot: [UInt32: UserNode] = [:]
    private var rootID: UInt32?
    private var ownSessionID: UInt32?
    private var speakingSnapshot: Set<UInt32> = []
    private var isTransmittingSnapshot = false
    private var wasConnected = false

    // MARK: - Item identity / expansion state

    private var channelItems: [UInt32: ChannelOutlineItem] = [:]
    private var userItems: [UInt32: ChannelOutlineItem] = [:]
    private var childrenCache: [UInt32: [ChannelOutlineItem]] = [:]

    /// channelID → the user's latched disclosure choice. Absent = follow
    /// live occupancy (`subtreeHasOccupants`). Ports the SwiftUI
    /// `userOverride: Bool?` @State semantics: live until the first
    /// manual toggle, then latched until the connection ends.
    private var expansionOverride: [UInt32: Bool] = [:]
    /// True while render() drives expandItem/collapseItem to reconcile —
    /// those delegate notifications are not user intent.
    private var isApplyingProgrammaticExpansion = false

    init(client: MumbleClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChannelSidebarViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let header = NSTextField(labelWithString: "Channels")
        header.font = NSFont.preferredFont(forTextStyle: .subheadline)
        header.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: .init("channel"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 13
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick(_:))

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholderLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        placeholderLabel.textColor = .secondaryLabelColor

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        footerLabel.textColor = .secondaryLabelColor
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 6
        footerStack.addArrangedSubview(footerDivider)
        footerStack.addArrangedSubview(footerLabel)
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.widthAnchor.constraint(equalTo: footerStack.widthAnchor).isActive = true

        let stack = NSStackView(views: [header, scrollView, placeholderLabel, footerStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            placeholderLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            self.render()
        }
        tracker?.start()
    }

    // MARK: - Render

    private func render() {
        let state = client.state
        let connected: Bool = (state == .connected)

        // Footer: shown whenever a server version is known.
        let version = client.serverVersion
        footerStack.isHidden = (version == nil)
        if let version {
            footerLabel.stringValue = "Server \(version)"
        }

        guard connected, let newRootID = client.rootChannelID,
              client.channels[newRootID] != nil else {
            // Placeholder mode. Tear down tree state when leaving a
            // connection so the next session starts from live occupancy
            // (this is the SwiftUI @State-destruction boundary).
            if wasConnected {
                channelsSnapshot = [:]
                usersSnapshot = [:]
                rootID = nil
                expansionOverride.removeAll()
                channelItems.removeAll()
                userItems.removeAll()
                childrenCache.removeAll()
                outlineView.reloadData()
            }
            wasConnected = false
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = Self.placeholderText(for: state)
            return
        }

        // Connected: snapshot, then decide reload granularity. The
        // speaking set churns per voice packet — that path must touch
        // only the affected user rows, never rebuild the tree.
        scrollView.isHidden = false
        placeholderLabel.isHidden = true

        let prevChannels = channelsSnapshot
        let prevUsers = usersSnapshot
        let prevSpeaking = speakingSnapshot
        let prevTransmitting = isTransmittingSnapshot
        let entering = !wasConnected
        wasConnected = true

        channelsSnapshot = client.channels
        usersSnapshot = client.users
        rootID = newRootID
        ownSessionID = client.sessionID
        speakingSnapshot = client.speakingSessions
        isTransmittingSnapshot = client.isTransmitting

        let treeChanged = entering
            || prevChannels != channelsSnapshot
            || prevUsers != usersSnapshot

        if treeChanged {
            if entering {
                expansionOverride.removeAll()
                channelItems.removeAll()
                userItems.removeAll()
            } else {
                // Prune interned items for channels/users that left —
                // otherwise the caches grow monotonically over a long
                // session as people churn through the server.
                channelItems = channelItems.filter { channelsSnapshot[$0.key] != nil }
                userItems = userItems.filter { usersSnapshot[$0.key] != nil }
            }
            childrenCache.removeAll()
            outlineView.reloadData()
            applyExpansionState()
        } else {
            var changed = prevSpeaking.symmetricDifference(speakingSnapshot)
            if prevTransmitting != isTransmittingSnapshot, let own = ownSessionID {
                changed.insert(own)
            }
            for sessionID in changed {
                if let item = userItems[sessionID] {
                    outlineView.reloadItem(item, reloadChildren: false)
                }
            }
        }
    }

    private static func placeholderText(for state: MumbleClient.ConnectionState) -> String {
        switch state {
        case .disconnected: "Use ⌘K to connect."
        case .connecting, .handshaking: "Loading channels…"
        case .connected: "No channels yet."
        case .failed: "Connection failed."
        }
    }

    // MARK: - Expansion semantics

    /// A channel is expanded by default iff it — or anything below it —
    /// has users. Keeps the sidebar scannable on huge servers by folding
    /// empty branches. Live until the user toggles the row, then latched.
    private func subtreeHasOccupants(_ channelID: UInt32) -> Bool {
        guard let node = channelsSnapshot[channelID] else { return false }
        if !node.userSessionIDs.isEmpty { return true }
        return node.childChannelIDs.contains { subtreeHasOccupants($0) }
    }

    private func effectiveExpanded(_ channelID: UInt32) -> Bool {
        expansionOverride[channelID] ?? subtreeHasOccupants(channelID)
    }

    private func applyExpansionState() {
        isApplyingProgrammaticExpansion = true
        defer { isApplyingProgrammaticExpansion = false }

        // Depth-first from the root so parents are realized before their
        // children are reconciled; collapsed subtrees aren't realized and
        // need no reconciliation until they expand.
        func reconcile(_ item: ChannelOutlineItem) {
            guard case .channel(let id) = item.kind else { return }
            let want = effectiveExpanded(id)
            let have = outlineView.isItemExpanded(item)
            if want && !have {
                outlineView.expandItem(item)
            } else if !want && have {
                outlineView.collapseItem(item)
            }
            if outlineView.isItemExpanded(item) {
                for child in children(of: item) {
                    reconcile(child)
                }
            }
        }
        if let rootID, let rootItem = channelItems[rootID] {
            reconcile(rootItem)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        latchUserExpansion(from: notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        latchUserExpansion(from: notification, expanded: false)
    }

    private func latchUserExpansion(from notification: Notification, expanded: Bool) {
        guard !isApplyingProgrammaticExpansion else { return }
        guard let item = notification.userInfo?["NSObject"] as? ChannelOutlineItem else {
            assertionFailure("Expansion notification without an item — userInfo key drift?")
            return
        }
        guard case .channel(let id) = item.kind else { return }
        expansionOverride[id] = expanded
    }

    // MARK: - Items / children

    private func channelItem(_ id: UInt32) -> ChannelOutlineItem {
        if let cached = channelItems[id] { return cached }
        let fresh = ChannelOutlineItem(.channel(id))
        channelItems[id] = fresh
        return fresh
    }

    private func userItem(_ id: UInt32) -> ChannelOutlineItem {
        if let cached = userItems[id] { return cached }
        let fresh = ChannelOutlineItem(.user(id))
        userItems[id] = fresh
        return fresh
    }

    /// Children of a channel: its users (sorted case-insensitively by
    /// name) first, then its child channels (position, then name —
    /// `ChannelTreeOrder`). Dangling IDs skipped. Cached per render pass.
    private func children(of item: ChannelOutlineItem?) -> [ChannelOutlineItem] {
        guard let item else {
            return rootID.map { [channelItem($0)] } ?? []
        }
        guard case .channel(let id) = item.kind else { return [] }
        if let cached = childrenCache[id] { return cached }
        guard let node = channelsSnapshot[id] else { return [] }

        let users = node.userSessionIDs
            .compactMap { usersSnapshot[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { userItem($0.id) }
        let channels = ChannelTreeOrder.sortedChildren(of: node, in: channelsSnapshot)
            .map { channelItem($0.id) }

        let result = users + channels
        childrenCache[id] = result
        return result
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? ChannelOutlineItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? ChannelOutlineItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? ChannelOutlineItem,
              case .channel = item.kind else { return false }
        return !children(of: item).isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // The tree has no selection concept — clicking a channel joins it.
        false
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let item = item as? ChannelOutlineItem else { return nil }
        switch item.kind {
        case .channel(let id):
            guard let node = channelsSnapshot[id] else { return nil }
            let cell = outlineView.makeView(withIdentifier: ChannelCellView.identifier,
                                            owner: nil) as? ChannelCellView ?? ChannelCellView()
            cell.configure(name: node.name)
            return cell
        case .user(let id):
            guard let user = usersSnapshot[id] else { return nil }
            let cell = outlineView.makeView(withIdentifier: UserCellView.identifier,
                                            owner: nil) as? UserCellView ?? UserCellView()
            let isOwn = (user.id == ownSessionID)
            let isSpeaking = isOwn ? isTransmittingSnapshot : speakingSnapshot.contains(user.id)
            cell.configure(user: user, isOwn: isOwn, isSpeaking: isSpeaking)
            return cell
        }
    }

    // MARK: - Click to join

    @objc private func handleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? ChannelOutlineItem,
              case .channel(let id) = item.kind else { return }
        // A click on the disclosure triangle toggles expansion; it must
        // not also join the channel (the SwiftUI DisclosureGroup kept
        // those separate too).
        if let event = NSApp.currentEvent {
            let point = outlineView.convert(event.locationInWindow, from: nil)
            if outlineView.frameOfOutlineCell(atRow: row).contains(point) { return }
        }
        Task { await client.moveToChannel(id) }
    }
}
