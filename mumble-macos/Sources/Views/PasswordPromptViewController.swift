import AppKit

/// Tiny "type the password to connect" sheet shown when the user picks a
/// saved server whose password isn't remembered (or whose keychain entry
/// is missing). The password is consumed for the connect attempt and is
/// not written back to the keychain — that's a separate "remember
/// password" toggle on the bookmark.
@MainActor
final class PasswordPromptViewController: NSViewController {
    private let serverLabel: String
    private let serverDetails: String
    private let onConnect: (String) -> Void
    private let onCancel: () -> Void

    private let passwordField = NSSecureTextField(string: "")

    init(serverLabel: String,
         serverDetails: String,
         onConnect: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.serverLabel = serverLabel
        self.serverDetails = serverDetails
        self.onConnect = onConnect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PasswordPromptViewController does not support NSCoding")
    }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Password for \(serverLabel)")
        title.font = NSFont.preferredFont(forTextStyle: .headline)
        title.lineBreakMode = .byTruncatingTail

        let details = NSTextField(labelWithString: serverDetails)
        details.font = NSFont.preferredFont(forTextStyle: .caption1)
        details.textColor = .secondaryLabelColor
        details.lineBreakMode = .byTruncatingMiddle

        passwordField.placeholderString = "Password"
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        connectButton.keyEquivalent = "\r"
        let buttonRow = NSStackView.sheetButtonRow(trailing: [cancelButton, connectButton])

        let stack = NSStackView(views: [title, details, passwordField, buttonRow])
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
            passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 360),
        ])

        view = root
    }

    @objc private func connect(_ sender: Any?) {
        let password = passwordField.stringValue
        endHostingSheet()
        onConnect(password)
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
        onCancel()
    }
}
