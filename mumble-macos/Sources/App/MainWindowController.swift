import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let client: MumbleClient
    private var pttMonitor: Any?
    private var pttDown = false

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
        installPTTMonitor()
    }

    /// Local monitor for PTT: hold ⌥Space while the window is focused.
    /// Global hotkeys require Input Monitoring permission; we'll add that
    /// later, in-app is enough for now.
    private func installPTTMonitor() {
        pttMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            // space = 49, with option modifier
            guard event.keyCode == 49, event.modifierFlags.contains(.option) else {
                return event
            }
            if event.type == .keyDown, !event.isARepeat, !self.pttDown {
                self.pttDown = true
                self.client.startTalking()
                return nil
            }
            if event.type == .keyUp, self.pttDown {
                self.pttDown = false
                self.client.stopTalking()
                return nil
            }
            return event
        }
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
