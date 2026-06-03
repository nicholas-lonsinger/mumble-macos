import AppKit

extension PasswordHandling {
    /// User-facing label, shared by the Quick Connect save sheet and the
    /// bookmark editor.
    var displayLabel: String {
        switch self {
        case .useStoredPassword: "Use saved password"
        case .noPasswordRequired: "No password required"
        case .promptEveryTime: "Ask every time"
        }
    }
}

/// Quick Connect sheet content.
///
/// Host/port/username persist across launches (UserDefaults, written
/// through on every edit — same semantics as the previous @AppStorage
/// fields). Password lives in `QuickConnectMemory` for the duration of
/// the session — wiped on quit by design (saved bookmarks use the
/// keychain instead).
@MainActor
final class ConnectViewController: NSViewController, NSTextFieldDelegate {
    private let onConnect: (ServerConnectionParameters) -> Void
    private let onCancel: () -> Void
    /// When the sheet is opened via a `mumble://` URL, the parsed URL lands
    /// here and overwrites the persisted form values on first load.
    private let prefill: MumbleURL?
    /// The URL's channel path travels with the form silently — there's no
    /// field for it in the UI but it has to survive into the connect
    /// parameters so the post-`ServerSync` join code in `MumbleClient`
    /// can use it.
    private var desiredChannelPath: [String] = []

    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")

    private let identityIcon = NSImageView()
    private let identityTitle = NSTextField(labelWithString: "")
    private let identityFingerprint = NSTextField(labelWithString: "")

    private var saveButton: NSButton!
    private var connectButton: NSButton!

    private enum DefaultsKey {
        static let host = "lastServerHost"
        static let port = "lastServerPort"
        static let username = "lastServerUsername"
    }

    init(prefill: MumbleURL?,
         onConnect: @escaping (ServerConnectionParameters) -> Void,
         onCancel: @escaping () -> Void) {
        self.prefill = prefill
        self.onConnect = onConnect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Connect to Mumble Server")
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        let form = NSGridView(views: [])
        let fields: [(String, NSTextField)] = [
            ("Host", hostField),
            ("Port", portField),
            ("Username", usernameField),
            ("Password", passwordField),
        ]
        for (label, field) in fields {
            let labelField = NSTextField(labelWithString: label)
            labelField.alignment = .right
            field.delegate = self
            form.addRow(with: [labelField, field])
        }
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 280

        // Identity indicator (loaded once — the identity only changes via
        // the Certificate Manager, which lives in its own window).
        identityTitle.font = NSFont.preferredFont(forTextStyle: .caption1)
        identityTitle.lineBreakMode = .byWordWrapping
        identityTitle.maximumNumberOfLines = 2
        identityFingerprint.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        identityFingerprint.textColor = .secondaryLabelColor
        identityFingerprint.lineBreakMode = .byTruncatingMiddle
        identityFingerprint.maximumNumberOfLines = 1
        let identityText = NSStackView(views: [identityTitle, identityFingerprint])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 1
        let identityRow = NSStackView(views: [identityIcon, identityText])
        identityRow.orientation = .horizontal
        identityRow.alignment = .firstBaseline
        identityRow.spacing = 6

        saveButton = NSButton(title: "Save…", target: self, action: #selector(openSaveSheet(_:)))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        connectButton.keyEquivalent = "\r"
        let buttonRow = NSStackView.sheetButtonRow(leading: [saveButton],
                                                   trailing: [cancelButton, connectButton])

        let stack = NSStackView(views: [title, form, identityRow, buttonRow])
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
            identityRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 440),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadPersistedFields()
        applyPrefillIfNeeded()
        reloadIdentity()
        updateButtonEnablement()
    }

    // MARK: - Field persistence

    private func loadPersistedFields() {
        let defaults = UserDefaults.standard
        let fallback = ServerConnectionParameters.defaultPublicTestServer
        hostField.stringValue = defaults.string(forKey: DefaultsKey.host) ?? fallback.host
        portField.stringValue = defaults.string(forKey: DefaultsKey.port) ?? String(fallback.port)
        usernameField.stringValue = defaults.string(forKey: DefaultsKey.username) ?? fallback.username
        passwordField.stringValue = QuickConnectMemory.shared.lastPassword
    }

    private func applyPrefillIfNeeded() {
        guard let prefill else { return }
        hostField.stringValue = prefill.host
        portField.stringValue = String(prefill.port)
        if let username = prefill.username {
            usernameField.stringValue = username
        }
        // Explicit password in the URL wins; otherwise leave the cached
        // session-scoped value alone so the user doesn't have to retype it.
        if let urlPassword = prefill.password {
            passwordField.stringValue = urlPassword
            QuickConnectMemory.shared.lastPassword = urlPassword
        }
        desiredChannelPath = prefill.channelPath
        persistFields()
    }

    /// Write-through on every edit, matching the @AppStorage behavior the
    /// SwiftUI form had: values survive Cancel.
    func controlTextDidChange(_ obj: Notification) {
        persistFields()
        QuickConnectMemory.shared.lastPassword = passwordField.stringValue
        updateButtonEnablement()
    }

    private func persistFields() {
        let defaults = UserDefaults.standard
        defaults.set(hostField.stringValue, forKey: DefaultsKey.host)
        defaults.set(portField.stringValue, forKey: DefaultsKey.port)
        defaults.set(usernameField.stringValue, forKey: DefaultsKey.username)
    }

    // MARK: - Identity indicator

    private func reloadIdentity() {
        if let summary = try? IdentityStore.shared.currentSummary() {
            identityIcon.image = NSImage(systemSymbolName: "person.badge.key.fill",
                                         accessibilityDescription: nil)
            identityIcon.contentTintColor = .systemGreen
            identityTitle.stringValue = "Presenting identity: \(summary.commonName)"
            identityTitle.textColor = .labelColor
            identityFingerprint.stringValue = summary.sha1Fingerprint
            identityFingerprint.isHidden = false
        } else {
            identityIcon.image = NSImage(systemSymbolName: "person.badge.key",
                                         accessibilityDescription: nil)
            identityIcon.contentTintColor = .secondaryLabelColor
            identityTitle.stringValue = "No client certificate — connecting as guest. Import one in \u{2318}Mumble ▸ Certificate Manager…."
            identityTitle.textColor = .secondaryLabelColor
            identityFingerprint.isHidden = true
        }
    }

    // MARK: - Validation

    private var canConnect: Bool {
        !hostField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(portField.stringValue) != nil
            && !usernameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func updateButtonEnablement() {
        connectButton.isEnabled = canConnect
        // Save… is enabled whenever the form has the minimum needed to
        // identify a server. The password may be empty — saving without
        // one is a valid pattern (e.g. for guest-friendly servers).
        saveButton.isEnabled = canConnect
    }

    private var currentParameters: ServerConnectionParameters {
        ServerConnectionParameters(
            host: hostField.stringValue.trimmingCharacters(in: .whitespaces),
            port: UInt16(portField.stringValue) ?? 64738,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespaces),
            password: passwordField.stringValue,
            desiredChannelPath: desiredChannelPath
        )
    }

    // MARK: - Actions

    @objc private func connect(_ sender: Any?) {
        guard canConnect else { return }
        onConnect(currentParameters)
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
    }

    // MARK: - Save…

    @objc private func openSaveSheet(_ sender: Any?) {
        // Default the label to host (matches the reference client's behavior
        // when the user adds a bookmark with no explicit name). Default the
        // mode to "use saved" if the user typed a password, otherwise "no
        // password" — that's the most likely intent given what they entered.
        let sheet = SaveServerViewController(
            defaultLabel: hostField.stringValue.trimmingCharacters(in: .whitespaces),
            groups: ServerBookStore.shared.groups.sorted { $0.sortIndex < $1.sortIndex },
            defaultGroupID: ServerBookStore.shared.group(of: .favorites)?.id,
            defaultHandling: passwordField.stringValue.isEmpty
                ? .noPasswordRequired
                : .useStoredPassword,
            onSave: { [weak self] label, groupID, handling in
                self?.performSave(label: label, groupID: groupID, handling: handling)
            }
        )
        view.window?.beginSheet(controller: sheet, title: "Save Server")
    }

    /// Returns an error message to display in the save sheet, or nil on
    /// success (the sheet closes itself).
    private func performSave(label: String,
                             groupID: UUID?,
                             handling: PasswordHandling) -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else {
            return "Display name can't be empty."
        }
        if let message = BookmarkFormValidation.validationError(
            port: portField.stringValue,
            handling: handling,
            password: passwordField.stringValue
        ) {
            return message
        }
        let portValue = UInt16(portField.stringValue) ?? 64738

        let server = SavedServer(
            label: trimmedLabel,
            host: hostField.stringValue.trimmingCharacters(in: .whitespaces),
            port: portValue,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespaces),
            groupID: groupID,
            passwordHandling: handling
        )
        ServerBookStore.shared.addServer(server)

        if handling == .useStoredPassword {
            do {
                try ServerPasswordStore.shared.setPassword(
                    passwordField.stringValue,
                    forServer: server.id
                )
            } catch {
                // Roll back the bookmark if we couldn't persist its password —
                // a half-saved entry is more confusing than a clean failure.
                try? ServerBookStore.shared.removeServer(id: server.id)
                return "Couldn't save password to keychain: \(error.localizedDescription)"
            }
        }
        return nil
    }
}

// MARK: - Save Server sheet

/// Nested sheet for "Save…" on the Quick Connect form: display name,
/// group, and password-handling for the new bookmark. The save itself
/// runs in `ConnectViewController.performSave`, which returns an error
/// string for this sheet to display (nil closes the sheet).
@MainActor
private final class SaveServerViewController: NSViewController, NSTextFieldDelegate {
    private let onSave: (String, UUID?, PasswordHandling) -> String?

    private let labelField: NSTextField
    private let groupPopup: GroupPopup
    private let handlingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!

    init(defaultLabel: String,
         groups: [ServerGroup],
         defaultGroupID: UUID?,
         defaultHandling: PasswordHandling,
         onSave: @escaping (String, UUID?, PasswordHandling) -> String?) {
        self.onSave = onSave
        self.labelField = NSTextField(string: defaultLabel)
        self.groupPopup = GroupPopup(groups: groups, selected: defaultGroupID)
        super.init(nibName: nil, bundle: nil)

        for handling in PasswordHandling.allCases {
            handlingPopup.addItem(withTitle: handling.displayLabel)
        }
        if let index = PasswordHandling.allCases.firstIndex(of: defaultHandling) {
            handlingPopup.selectItem(at: index)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SaveServerViewController does not support NSCoding")
    }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Save Server")
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        let form = NSGridView(views: [])
        labelField.delegate = self
        let rows: [(String, NSView)] = [
            ("Display Name", labelField),
            ("Group", groupPopup.control),
            ("Password handling", handlingPopup),
        ]
        for (label, control) in rows {
            let labelView = NSTextField(labelWithString: label)
            labelView.alignment = .right
            form.addRow(with: [labelView, control])
        }
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 200

        errorLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView.sheetButtonRow(trailing: [cancelButton, saveButton])

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
            root.widthAnchor.constraint(equalToConstant: 360),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateSaveEnablement()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateSaveEnablement()
    }

    private func updateSaveEnablement() {
        saveButton.isEnabled = !labelField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func save(_ sender: Any?) {
        let handling = PasswordHandling.allCases[handlingPopup.indexOfSelectedItem]
        if let error = onSave(labelField.stringValue, groupPopup.selectedGroupID, handling) {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
        } else {
            endHostingSheet()
        }
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
    }
}
