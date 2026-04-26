import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let client: MumbleClient
    /// Routes user-configured shortcuts (Push-to-Talk, Mute, Whisper, …)
    /// to actions on the client. Replaces the previously hardcoded Fn+Control
    /// `flagsChanged` monitor; the default seeded binding in `ShortcutsStore`
    /// preserves the same chord on first launch.
    private var shortcutDispatcher: ShortcutDispatcher?

    init(client: MumbleClient) {
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
        shortcutDispatcher = ShortcutDispatcher(client: client, store: ShortcutsStore.shared)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController does not support NSCoding")
    }

    @objc func showQuickConnectSheet(_ sender: Any?) {
        presentQuickConnectSheet(prefill: nil)
    }

    /// Open the Quick Connect sheet with form values pre-populated from a
    /// parsed `mumble://` URL. If a sheet is already attached it is replaced
    /// — the newest link wins, matching how the reference client treats
    /// URL opens.
    func presentQuickConnectSheet(prefill: MumbleURL?) {
        guard let window else { return }
        if let existing = window.attachedSheet {
            window.endSheet(existing)
        }
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Connect to Server"
        let sheetView = ConnectView(onConnect: { [weak self] params in
            guard let self, let window = self.window else { return }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            Task { await self.client.connect(to: params) }
        }, onCancel: { [weak window] in
            guard let window, let sheet = window.attachedSheet else { return }
            window.endSheet(sheet)
        }, prefill: prefill)
        sheetWindow.contentView = NSHostingView(rootView: sheetView)
        window.beginSheet(sheetWindow)
    }

    @objc func disconnect(_ sender: Any?) {
        Task { await client.disconnect() }
    }
}
