import AppKit

/// "New Group" sheet: a single name field. Add stays disabled until the
/// trimmed name is non-empty; commits a user-kind group.
@MainActor
final class AddGroupViewController: NSViewController, NSTextFieldDelegate {
    private let nameField = NSTextField(string: "")
    private var addButton: NSButton!

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "New Group")
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        addButton = NSButton(title: "Add", target: self, action: #selector(commit(_:)))
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        let buttonRow = NSStackView.sheetButtonRow(trailing: [cancelButton, addButton])

        let stack = NSStackView(views: [title, nameField, buttonRow])
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
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 320),
        ])

        view = root
    }

    func controlTextDidChange(_ obj: Notification) {
        addButton.isEnabled = !nameField.stringValue
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func commit(_ sender: Any?) {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ServerBookStore.shared.addGroup(ServerGroup(name: trimmed, kind: .user))
        endHostingSheet()
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
    }
}
