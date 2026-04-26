import AppKit
import OSLog
import SwiftUI

/// Owns the standalone Servers window. The window hosts the SwiftUI
/// `ServersView` via `NSHostingView`, AppKit-first per the project's
/// "no double-bridging" rule (CLAUDE.md → "AppKit-first, never double-
/// bridge"). The controller's job is plumbing: it wires the view's
/// connect-requested callback to the shared `MumbleClient`, brings the
/// main window forward, and hides itself so the user lands directly in
/// the channel list — which matches the reference Mumble client's
/// server-browser-on-connect behavior.
@MainActor
final class ServersWindowController: NSWindowController {
    private let client: MumbleClient
    private weak var mainWindow: NSWindow?

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "servers-window")

    init(client: MumbleClient, mainWindow: NSWindow?) {
        self.client = client
        self.mainWindow = mainWindow

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Servers"
        window.setFrameAutosaveName("ServersWindow")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)

        super.init(window: window)

        let view = ServersView(onConnectRequested: { [weak self] server, password in
            self?.handleConnectRequest(server: server, password: password)
        })
        window.contentView = NSHostingView(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ServersWindowController does not support NSCoding")
    }

    // MARK: - Connect dispatch

    private func handleConnectRequest(server: SavedServer, password: String) {
        let params = ServerConnectionParameters(
            host: server.host,
            port: server.port,
            username: server.username,
            password: password
        )
        Self.log.info("Connect requested: server=\(server.label, privacy: .public) host=\(server.host, privacy: .public):\(server.port, privacy: .public)")

        // Stamp lastConnectedAt eagerly. Even if the connection ultimately
        // fails, the user *attempted* this server most recently — that's
        // the signal we'll want for "recently used" sorting later.
        var stamped = server
        stamped.lastConnectedAt = Date()
        try? ServerBookStore.shared.updateServer(stamped)

        Task { await client.connect(to: params) }

        // Bring the main window forward and orderOut self so the user lands
        // in the channel list. orderOut (not close) keeps frame autosave +
        // controller state intact for the next ⌘K.
        mainWindow?.makeKeyAndOrderFront(nil)
        window?.orderOut(nil)
    }
}
