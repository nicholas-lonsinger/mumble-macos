import AppKit

/// Modal sheet for editing a Whisper/Shout binding's target. Channel mode
/// only for MVP — user-list mode is deferred. Mirrors the layout of the
/// reference Mumble client's "Whisper Target" dialog.
///
/// The channel picker is a single-column table showing the tree always
/// fully expanded, indented by depth (`WhisperTargetTree.flattenTree`,
/// computed once at load — the channel snapshot is handed in by the
/// presenter, so a connect/disconnect mid-edit doesn't yank rows around).
@MainActor
final class WhisperTargetViewController: NSViewController,
                                         NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case special(label: String, mode: WhisperTarget.ChannelMode)
        case divider
        case placeholder
        case channel(WhisperTargetTree.TreeRow)
    }

    private var target: WhisperTarget
    private let rows: [Row]
    private let onSave: (WhisperTarget) -> Void
    private let onCancel: () -> Void

    private let tableView = NSTableView()
    private let restrictGroupField = NSTextField(string: "")
    private let linkedCheckbox = NSButton(checkboxWithTitle: "Shout to Linked channels",
                                          target: nil, action: nil)
    private let subchannelsCheckbox = NSButton(checkboxWithTitle: "Shout to subchannels",
                                               target: nil, action: nil)
    private var saveButton: NSButton!

    init(initial: WhisperTarget,
         channels: [UInt32: ChannelNode],
         rootChannelID: UInt32?,
         onSave: @escaping (WhisperTarget) -> Void,
         onCancel: @escaping () -> Void) {
        self.target = initial
        self.onSave = onSave
        self.onCancel = onCancel

        var rows: [Row] = [
            .special(label: "Current", mode: .current),
            .special(label: "Root", mode: .root),
            .special(label: "Parent", mode: .parent),
            .divider,
        ]
        let flattened = WhisperTargetTree.flattenTree(channels: channels, rootID: rootChannelID)
        if flattened.isEmpty {
            rows.append(.placeholder)
        } else {
            rows.append(contentsOf: flattened.map(Row.channel))
        }
        self.rows = rows

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WhisperTargetViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Whisper Target")
        title.font = NSFont.preferredFont(forTextStyle: .title3)

        // Mode picker — Channel only in this version, so it's disabled.
        let modeLabel = NSTextField(labelWithString: "Shout/Whisper to:")
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItem(withTitle: "Channel")
        modePopup.isEnabled = false
        modePopup.toolTip = "Only Channel-mode targets are available in this version."
        modePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8

        // Channel picker table inside a titled box.
        tableView.addTableColumn(NSTableColumn(identifier: .init("channel")))
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.style = .plain
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let box = NSBox()
        box.title = "Channel Target"
        // NSBox sizes its contentView by autoresizing, so the scroll view
        // must keep its autoresizing mask (no Auto Layout inside the box).
        // The box itself gets the height floor and absorbs the stack's
        // vertical slack — the AppKit equivalent of the SwiftUI layout's
        // minHeight 200 picker + trailing Spacer.
        box.contentView = scroll
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 224).isActive = true
        box.setContentHuggingPriority(.init(1), for: .vertical)

        // Restrict-to-group field.
        let restrictLabel = NSTextField(labelWithString: "Restrict to Group")
        restrictGroupField.stringValue = target.restrictGroup
        restrictGroupField.translatesAutoresizingMaskIntoConstraints = false
        let restrictRow = NSStackView(views: [restrictLabel, restrictGroupField])
        restrictRow.orientation = .horizontal
        restrictRow.spacing = 8
        restrictGroupField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Checkboxes.
        linkedCheckbox.state = target.includeLinks ? .on : .off
        subchannelsCheckbox.state = target.includeChildren ? .on : .off
        let checkboxRow = NSStackView(views: [linkedCheckbox, subchannelsCheckbox])
        checkboxRow.orientation = .horizontal
        checkboxRow.spacing = 16

        // Buttons.
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView.sheetButtonRow(trailing: [cancelButton, saveButton])

        let stack = NSStackView(views: [title, modeRow, box, restrictRow, checkboxRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor),
            restrictRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
        preferredContentSize = NSSize(width: 480, height: 460)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        selectInitialRow()
        updateSaveEnablement()
    }

    // MARK: - Selection plumbing

    private func selectInitialRow() {
        let index = rows.firstIndex { row in
            switch (row, target.channelMode) {
            case let (.special(_, mode), current) where mode == current:
                return true
            case let (.channel(treeRow), .byID):
                return treeRow.channelID == target.channelID
            default:
                return false
            }
        }
        if let index {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    private func updateSaveEnablement() {
        let isValid: Bool
        switch target.channelMode {
        case .current, .root, .parent: isValid = true
        case .byID: isValid = target.channelID != nil
        }
        saveButton.isEnabled = isValid
    }

    // MARK: - Actions

    @objc private func save(_ sender: Any?) {
        target.restrictGroup = restrictGroupField.stringValue
        target.includeLinks = (linkedCheckbox.state == .on)
        target.includeChildren = (subchannelsCheckbox.state == .on)
        onSave(target)
        endHostingSheet()
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
        endHostingSheet()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch rows[row] {
        case let .special(label, _):
            return makeTextCell(text: label, indent: 0, secondary: false)
        case .divider:
            let box = NSBox()
            box.boxType = .separator
            let cell = NSTableCellView()
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                box.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .placeholder:
            return makeTextCell(text: "Connect to a server to browse channels.",
                                indent: 0, secondary: true)
        case let .channel(treeRow):
            return makeTextCell(text: treeRow.name.isEmpty ? "Root" : treeRow.name,
                                indent: CGFloat(treeRow.depth) * 14, secondary: false)
        }
    }

    private func makeTextCell(text: String, indent: CGFloat, secondary: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if secondary { label.textColor = .secondaryLabelColor }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6 + indent),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .special, .channel: return true
        case .divider, .placeholder: return false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .divider = rows[row] { return 9 }
        return tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        switch rows[row] {
        case let .special(_, mode):
            target.channelMode = mode
            target.channelID = nil
        case let .channel(treeRow):
            target.channelMode = .byID
            target.channelID = treeRow.channelID
        case .divider, .placeholder:
            break
        }
        updateSaveEnablement()
    }
}
