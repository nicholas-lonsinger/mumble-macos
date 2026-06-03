import AppKit

/// Shortcuts preferences tab. Lists the user's `ShortcutBinding`s in a
/// three-column table and lets them rebind, add, or remove rows.
/// Click-to-capture in the Shortcut column accepts modifier-only chords,
/// keys, or mouse buttons.
@MainActor
final class ShortcutsViewController: NSViewController,
                                     NSTableViewDataSource, NSTableViewDelegate {
    private let client: MumbleClient
    private let dispatcher: ShortcutDispatcher
    private let store = ShortcutsStore.shared
    private var tracker: ObservationTracker?

    private let tableView = NSTableView()
    private var removeButton: NSButton!

    /// In-flight binding-capture state. While non-nil, a local NSEvent
    /// monitor owns all input (suppressed — the press must not also type
    /// into fields or fire menu shortcuts; this is distinct from the
    /// "no suppression" rule for live shortcuts).
    private struct CaptureState {
        let bindingID: UUID
        /// Currently held modifiers — drives the live preview text.
        var liveModifiers: ShortcutModifiers = []
        /// Largest modifier set seen during this capture. Committed when
        /// the user releases all modifiers.
        var maxModifiers: ShortcutModifiers = []
    }

    private var captureState: CaptureState?
    private var captureMonitor: Any?

    private enum ColumnID {
        static let function = NSUserInterfaceItemIdentifier("function")
        static let data = NSUserInterfaceItemIdentifier("data")
        static let shortcut = NSUserInterfaceItemIdentifier("shortcut")
    }

    init(client: MumbleClient, dispatcher: ShortcutDispatcher) {
        self.client = client
        self.dispatcher = dispatcher
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutsViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let headerNote = NSTextField(wrappingLabelWithString:
            "Shortcuts work system-wide and are not suppressed — bound keys still type into focused fields and bound mouse buttons still click through. macOS will ask for Input Monitoring permission the first time you bind a key or modifier."
        )
        headerNote.font = NSFont.preferredFont(forTextStyle: .callout)
        headerNote.textColor = .secondaryLabelColor
        headerNote.isSelectable = false

        let functionColumn = NSTableColumn(identifier: ColumnID.function)
        functionColumn.title = "Function"
        functionColumn.width = 150
        functionColumn.resizingMask = []
        let dataColumn = NSTableColumn(identifier: ColumnID.data)
        dataColumn.title = "Data"
        dataColumn.width = 160
        dataColumn.resizingMask = []
        let shortcutColumn = NSTableColumn(identifier: ColumnID.shortcut)
        shortcutColumn.title = "Shortcut"
        shortcutColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(functionColumn)
        tableView.addTableColumn(dataColumn)
        tableView.addTableColumn(shortcutColumn)
        tableView.allowsMultipleSelection = false
        tableView.style = .inset
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus",
                                                accessibilityDescription: "Add shortcut")!,
                                 target: self, action: #selector(showAddMenu(_:)))
        addButton.isBordered = false
        addButton.toolTip = "Add shortcut"
        removeButton = NSButton(image: NSImage(systemSymbolName: "minus",
                                               accessibilityDescription: "Remove selected shortcut")!,
                                target: self, action: #selector(removeSelected(_:)))
        removeButton.isBordered = false
        removeButton.toolTip = "Remove selected shortcut"
        removeButton.isEnabled = false

        let restoreButton = NSButton(title: "Restore Defaults",
                                     target: self, action: #selector(restoreDefaults(_:)))
        restoreButton.isBordered = false
        restoreButton.contentTintColor = .controlAccentColor

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [addButton, removeButton, footerSpacer, restoreButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [headerNote, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            headerNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            // Bindings drive the rows; channel names feed the whisper
            // summaries in the Data column.
            _ = self.store.bindings
            _ = self.client.channels
            self.reloadPreservingSelection()
        }
        tracker?.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // A capture left running would keep input suppressed and the
        // dispatcher paused with no UI to escape it.
        cancelCapture()
    }

    private func reloadPreservingSelection() {
        let selectedID = selectedBindingID
        tableView.reloadData()
        if let selectedID,
           let row = store.bindings.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateRemoveEnablement()
    }

    private var selectedBindingID: UUID? {
        let row = tableView.selectedRow
        guard row >= 0, row < store.bindings.count else { return nil }
        return store.bindings[row].id
    }

    private func updateRemoveEnablement() {
        removeButton.isEnabled = (tableView.selectedRow >= 0)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.bindings.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < store.bindings.count, let tableColumn else { return nil }
        let binding = store.bindings[row]
        switch tableColumn.identifier {
        case ColumnID.function:
            return makeLabelCell(text: binding.action.displayName)
        case ColumnID.data:
            return makeDataCell(for: binding)
        case ColumnID.shortcut:
            return makeShortcutCell(for: binding)
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveEnablement()
    }

    // MARK: - Cells

    private func makeLabelCell(text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeDataCell(for binding: ShortcutBinding) -> NSTableCellView {
        guard binding.action == .whisperShout else {
            return makeLabelCell(text: "")
        }
        let summary = binding.whisperTarget?.summary(channelName: { [weak self] id in
            self?.client.channels[id]?.name
        })

        let cell = NSTableCellView()
        let button = NSButton(title: summary ?? "Configure…",
                              target: self, action: #selector(editWhisperTarget(_:)))
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        // Surface the full target name on hover for channels whose names
        // exceed the column width (Mumble subchannel naming conventions
        // can run long).
        button.toolTip = summary ?? "Configure…"
        if binding.whisperTarget == nil {
            // Unconfigured reads as a link so it's obviously actionable.
            button.attributedTitle = NSAttributedString(
                string: "Configure…",
                attributes: [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                ]
            )
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeShortcutCell(for binding: ShortcutBinding) -> NSTableCellView {
        let isCapturing = (captureState?.bindingID == binding.id)
        let text: String
        if isCapturing {
            let live = captureState?.liveModifiers.displayString ?? ""
            text = live.isEmpty ? "Press a key, modifier chord, or mouse button…" : "\(live) …"
        } else {
            text = binding.trigger?.displayString ?? "Click to set"
        }

        let cell = NSTableCellView()
        let button = NSButton(title: text, target: self, action: #selector(beginCaptureFromCell(_:)))
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        if isCapturing {
            button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.layer?.borderWidth = 1
            let font = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font,
            ])
        } else {
            button.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            button.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
        ])
        return cell
    }

    // MARK: - Toolbar actions

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for action in ShortcutAction.allCases {
            let item = NSMenuItem(title: action.displayName,
                                  action: #selector(addBindingFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func addBindingFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = ShortcutAction(rawValue: raw) else { return }
        let binding = ShortcutBinding(
            action: action,
            trigger: nil,
            whisperTarget: action.requiresWhisperTarget ? WhisperTarget() : nil
        )
        store.add(binding)
        if let row = store.bindings.firstIndex(where: { $0.id == binding.id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let id = selectedBindingID else { return }
        if captureState?.bindingID == id { cancelCapture() }
        store.remove(id: id)
        tableView.deselectAll(nil)
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        cancelCapture()
        store.restoreDefaults()
        tableView.deselectAll(nil)
    }

    // MARK: - Whisper target editing

    @objc private func editWhisperTarget(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < store.bindings.count else { return }
        let binding = store.bindings[row]
        guard binding.action == .whisperShout else { return }

        let editor = WhisperTargetViewController(
            initial: binding.whisperTarget ?? WhisperTarget(),
            channels: client.channels,
            rootChannelID: client.rootChannelID,
            onSave: { [weak self] newTarget in
                guard let self,
                      var updated = self.store.bindings.first(where: { $0.id == binding.id })
                else { return }
                updated.whisperTarget = newTarget
                self.store.update(updated)
            },
            onCancel: {}
        )
        view.window?.beginSheet(controller: editor, title: "Whisper Target")
    }

    // MARK: - Capture flow

    @objc private func beginCaptureFromCell(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < store.bindings.count else { return }
        beginCapture(rowID: store.bindings[row].id)
    }

    private func beginCapture(rowID: UUID) {
        cancelCapture()
        dispatcher.pause()
        captureState = CaptureState(bindingID: rowID)
        reloadShortcutCell(forBindingID: rowID)
        captureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleCaptureEvent(event)
            // Suppress during capture so the press doesn't also reach a
            // text field, fire menu shortcuts, or click through. This is
            // distinct from the "no suppression" rule for live shortcuts.
            return nil
        }
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        guard var state = captureState else { return }
        switch event.type {
        case .flagsChanged:
            let mods = ShortcutModifiers.from(event.modifierFlags)
            state.liveModifiers = mods
            if mods.isEmpty, !state.maxModifiers.isEmpty {
                // All modifiers released — commit a modifier-only chord
                // using the peak set the user held during this capture.
                commitCapture(.modifiersOnly(modifiers: state.maxModifiers))
            } else {
                state.maxModifiers.formUnion(mods)
                captureState = state
                reloadShortcutCell(forBindingID: state.bindingID)
            }
        case .keyDown:
            // Esc cancels.
            if event.keyCode == 0x35 {
                cancelCapture()
                return
            }
            let mods = ShortcutModifiers.from(event.modifierFlags)
            let name = ShortcutTrigger.keyDisplayName(
                forKeyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
            )
            commitCapture(.key(modifiers: mods, keyCode: event.keyCode, displayName: name))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let mods = ShortcutModifiers.from(event.modifierFlags)
            commitCapture(.mouseButton(modifiers: mods, buttonNumber: event.buttonNumber))
        default:
            break
        }
    }

    private func commitCapture(_ trigger: ShortcutTrigger) {
        guard let state = captureState,
              var binding = store.bindings.first(where: { $0.id == state.bindingID }) else {
            cancelCapture()
            return
        }
        binding.trigger = trigger
        store.update(binding)
        cancelCapture()
    }

    private func cancelCapture() {
        if let monitor = captureMonitor {
            NSEvent.removeMonitor(monitor)
            captureMonitor = nil
        }
        let endedID = captureState?.bindingID
        captureState = nil
        dispatcher.resume()
        if let endedID {
            reloadShortcutCell(forBindingID: endedID)
        }
    }

    private func reloadShortcutCell(forBindingID id: UUID) {
        guard let row = store.bindings.firstIndex(where: { $0.id == id }) else { return }
        let column = tableView.column(withIdentifier: ColumnID.shortcut)
        guard column >= 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: column))
    }
}
