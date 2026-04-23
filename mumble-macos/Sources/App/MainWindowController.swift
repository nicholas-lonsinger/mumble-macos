import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let client: MumbleClient

    init(client: MumbleClient = MumbleClient()) {
        self.client = client

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mumble"
        window.setFrameAutosaveName("MumbleMainWindow")
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)

        super.init(window: window)

        window.delegate = self
        let rootView = MainView().environment(client)
        window.contentView = NSHostingView(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController does not support NSCoding")
    }

    @objc func showConnectSheet(_ sender: Any?) {
        guard let window else { return }
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Connect to Server"
        let sheetView = ConnectView { [weak self] params in
            guard let self, let window = self.window else { return }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            Task { await self.client.connect(to: params) }
        } onCancel: { [weak window] in
            guard let window, let sheet = window.attachedSheet else { return }
            window.endSheet(sheet)
        }
        sheetWindow.contentView = NSHostingView(rootView: sheetView)
        window.beginSheet(sheetWindow)
    }

    @objc func disconnect(_ sender: Any?) {
        Task { await client.disconnect() }
    }
}
