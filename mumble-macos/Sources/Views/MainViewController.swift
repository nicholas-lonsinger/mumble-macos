import AppKit

/// Root content of the main window: a split view with the channel-tree
/// sidebar and the status/welcome detail pane. Each pane owns its own
/// `ObservationTracker`, so channel churn re-renders only the sidebar and
/// banner-state flips only the detail — independence by construction.
@MainActor
final class MainViewController: NSSplitViewController {
    private let client: MumbleClient
    private var titleTracker: ObservationTracker?

    init(client: MumbleClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: ChannelSidebarViewController(client: client)
        )
        sidebarItem.minimumThickness = 240
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(
            viewController: DetailViewController(client: client)
        )
        addSplitViewItem(detailItem)

        splitView.autosaveName = "MumbleMainSplit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainViewController does not support NSCoding")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Window exists from here on; drive its title from the connection
        // state (ports MainView.titleText).
        guard titleTracker == nil else { return }
        titleTracker = ObservationTracker { [weak self] in
            guard let self else { return }
            self.view.window?.title = Self.title(for: self.client.state)
        }
        titleTracker?.start()
    }

    private static func title(for state: MumbleClient.ConnectionState) -> String {
        switch state {
        case .disconnected: "Mumble"
        case .connecting: "Connecting…"
        case .handshaking: "Authenticating…"
        case .connected: "Mumble"
        case .failed: "Mumble — disconnected"
        }
    }
}
