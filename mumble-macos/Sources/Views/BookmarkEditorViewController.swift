import AppKit

/// Add / Edit bookmark sheet.
///
/// Owns the whole save flow, including the keychain invariant: a keychain
/// entry exists for the bookmark **iff** `passwordHandling ==
/// .useStoredPassword`. Edit always rewrites the stored password on save
/// (repairing the recovery case where the keychain entry went missing),
/// and deletes it when the handling moves away from stored.
@MainActor
final class BookmarkEditorViewController: NSViewController, NSTextFieldDelegate {
    enum Mode {
        case add(initialGroupID: UUID?)
        case edit(SavedServer.ID)
    }

    private let mode: Mode
    private let bookStore: ServerBookStore
    private let groups: [ServerGroup]
    private let onConnectAfterSave: ((SavedServer) -> Void)?
    /// Set when `.edit` couldn't resolve its server (deleted out from
    /// under the sheet). Save degrades to a close, matching the old view.
    private var loadFailed = false

    private let labelField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "64738")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let handlingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!
    private var saveAndConnectButton: NSButton?

    init(mode: Mode,
         bookStore: ServerBookStore = .shared,
         onConnectAfterSave: ((SavedServer) -> Void)? = nil) {
        self.mode = mode
        self.bookStore = bookStore
        self.groups = bookStore.groups.sorted { $0.sortIndex < $1.sortIndex }
        self.onConnectAfterSave = onConnectAfterSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BookmarkEditorViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let titleText: String
        switch mode {
        case .add: titleText = "New Server"
        case .edit: titleText = "Edit Server"
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        for handling in PasswordHandling.allCases {
            handlingPopup.addItem(withTitle: handling.displayLabel)
        }
        handlingPopup.target = self
        handlingPopup.action = #selector(handlingChanged(_:))

        groupPopup.addItem(withTitle: "Top Level")
        for group in groups {
            groupPopup.addItem(withTitle: group.name)
        }

        let form = NSGridView(views: [])
        for (label, control) in [
            ("Display Name", labelField as NSView),
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Password", passwordField),
            ("Password handling", handlingPopup),
            ("Group", groupPopup),
        ] {
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            form.addRow(with: [labelView, control])
        }
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 260
        for field in [labelField, hostField, portField, usernameField, passwordField] {
            field.delegate = self
        }

        errorLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var buttons: [NSView] = [spacer, cancelButton]
        // `Save & Connect` only exists in edit mode — editing a bookmark
        // and connecting in one step shouldn't need two round-trips.
        if case .edit = mode, onConnectAfterSave != nil {
            let saveConnect = NSButton(title: "Save & Connect",
                                       target: self, action: #selector(saveAndConnect(_:)))
            saveAndConnectButton = saveConnect
            buttons.append(saveConnect)
        }
        buttons.append(saveButton)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [title, form, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch mode {
        case .add(let initialGroupID):
            selectHandling(.useStoredPassword)
            selectGroup(initialGroupID)
        case .edit(let serverID):
            if let server = bookStore.server(id: serverID) {
                labelField.stringValue = server.label
                hostField.stringValue = server.host
                portField.stringValue = String(server.port)
                usernameField.stringValue = server.username
                passwordField.stringValue =
                    ((try? ServerPasswordStore.shared.password(forServer: serverID)) ?? nil) ?? ""
                selectHandling(server.passwordHandling)
                selectGroup(server.groupID)
            } else {
                loadFailed = true
                showError("Server no longer exists.")
            }
        }
        refreshControlState()
    }

    // MARK: - Selection helpers

    private func selectHandling(_ handling: PasswordHandling) {
        if let index = PasswordHandling.allCases.firstIndex(of: handling) {
            handlingPopup.selectItem(at: index)
        }
    }

    private var selectedHandling: PasswordHandling {
        PasswordHandling.allCases[handlingPopup.indexOfSelectedItem]
    }

    private func selectGroup(_ groupID: UUID?) {
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groupPopup.selectItem(at: index + 1)   // +1 for "Top Level"
        } else {
            groupPopup.selectItem(at: 0)
        }
    }

    private var selectedGroupID: UUID? {
        let index = groupPopup.indexOfSelectedItem
        return index > 0 ? groups[index - 1].id : nil
    }

    // MARK: - Validation

    func controlTextDidChange(_ obj: Notification) {
        refreshControlState()
    }

    @objc private func handlingChanged(_ sender: Any?) {
        refreshControlState()
    }

    private var canSave: Bool {
        guard !labelField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
              !hostField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty,
              UInt16(portField.stringValue) != nil,
              !usernameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        // .useStoredPassword needs an actual password to store. The other
        // modes don't depend on the field.
        if selectedHandling == .useStoredPassword, passwordField.stringValue.isEmpty {
            return false
        }
        return true
    }

    private func refreshControlState() {
        passwordField.isEnabled = (selectedHandling != .noPasswordRequired)
        let enabled = canSave && !loadFailed
        saveButton.isEnabled = enabled || loadFailed   // loadFailed: Save degrades to close
        saveAndConnectButton?.isEnabled = enabled
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    // MARK: - Save

    @objc private func save(_ sender: Any?) {
        performSave(thenConnect: false)
    }

    @objc private func saveAndConnect(_ sender: Any?) {
        performSave(thenConnect: true)
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
    }

    private func performSave(thenConnect: Bool) {
        guard !loadFailed else {
            endHostingSheet()
            return
        }
        guard let port = UInt16(portField.stringValue) else {
            showError("Port must be 0–65535.")
            return
        }
        let handling = selectedHandling
        if handling == .useStoredPassword, passwordField.stringValue.isEmpty {
            showError("Password is required when 'Use saved password' is selected.")
            return
        }

        switch mode {
        case .add:
            let server = SavedServer(
                label: labelField.stringValue.trimmingCharacters(in: .whitespaces),
                host: hostField.stringValue.trimmingCharacters(in: .whitespaces),
                port: port,
                username: usernameField.stringValue.trimmingCharacters(in: .whitespaces),
                groupID: selectedGroupID,
                passwordHandling: handling
            )
            bookStore.addServer(server)
            if handling == .useStoredPassword {
                do {
                    try ServerPasswordStore.shared.setPassword(passwordField.stringValue,
                                                               forServer: server.id)
                } catch {
                    try? bookStore.removeServer(id: server.id)
                    showError("Couldn't save password: \(error.localizedDescription)")
                    return
                }
            }
            endHostingSheet()

        case .edit(let serverID):
            guard var server = bookStore.server(id: serverID) else {
                showError("Server no longer exists.")
                return
            }
            let priorHandling = server.passwordHandling
            server.label = labelField.stringValue.trimmingCharacters(in: .whitespaces)
            server.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            server.port = port
            server.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
            server.groupID = selectedGroupID
            server.passwordHandling = handling
            do {
                try bookStore.updateServer(server)
            } catch {
                showError("Couldn't save: \(error.localizedDescription)")
                return
            }

            // Maintain the invariant: keychain has an entry iff
            // passwordHandling == .useStoredPassword. Always write on
            // .useStoredPassword (rather than only when the value changed)
            // so that Save also repairs the recovery case where the
            // keychain entry has gone missing — one keychain write per
            // save is cheap.
            do {
                switch handling {
                case .useStoredPassword:
                    try ServerPasswordStore.shared.setPassword(passwordField.stringValue,
                                                               forServer: serverID)
                case .noPasswordRequired, .promptEveryTime:
                    if priorHandling == .useStoredPassword {
                        try ServerPasswordStore.shared.deletePassword(forServer: serverID)
                    }
                }
            } catch {
                showError("Couldn't update password: \(error.localizedDescription)")
                return
            }

            endHostingSheet()
            if thenConnect {
                onConnectAfterSave?(server)
            }
        }
    }
}
