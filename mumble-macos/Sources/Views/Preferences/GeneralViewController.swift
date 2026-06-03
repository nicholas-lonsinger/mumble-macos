import AppKit

/// General preferences tab. First in the toolbar order.
///
/// Hosts a single knob: re-establish the most recent connection on app
/// launch. The companion `LastConnectedServerStore` captures the params
/// on `ServerSync` and clears them when the user disconnects deliberately,
/// so this only fires if the previous session ended via "quit while still
/// connected" (or a crash).
@MainActor
final class GeneralViewController: NSViewController {
    private let store = GeneralSettingsStore.shared
    private var tracker: ObservationTracker?

    private let reconnectCheckbox = NSButton(
        checkboxWithTitle: "Reconnect to last server on launch",
        target: nil,
        action: nil
    )

    override func loadView() {
        let root = NSView()

        let header = NSTextField(labelWithString: "Startup")
        header.font = NSFont.preferredFont(forTextStyle: .headline)

        reconnectCheckbox.target = self
        reconnectCheckbox.action = #selector(toggleReconnect(_:))

        let footer = NSTextField(wrappingLabelWithString:
            "When you quit while still connected, the next launch will reconnect to that server automatically. Disconnecting from the File menu before you quit clears the saved server, so the app won't reconnect to somewhere you intentionally left."
        )
        footer.font = NSFont.preferredFont(forTextStyle: .callout)
        footer.textColor = .secondaryLabelColor
        footer.isSelectable = false

        let stack = NSStackView(views: [header, reconnectCheckbox, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // Content hugs the top; the rest of the tab is empty space.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            self.reconnectCheckbox.state = self.store.reconnectOnLaunch ? .on : .off
        }
        tracker?.start()
    }

    @objc private func toggleReconnect(_ sender: NSButton) {
        store.reconnectOnLaunch = (sender.state == .on)
    }
}
