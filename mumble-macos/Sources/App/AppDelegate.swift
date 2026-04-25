import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var certificateManagerController: CertificateManagerWindowController?
    /// A URL that arrived before `applicationDidFinishLaunching(_:)` created
    /// the main window. Replayed once the window exists.
    private var pendingLaunchURL: MumbleURL?

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller

        NSApp.activate()

        if let url = pendingLaunchURL {
            pendingLaunchURL = nil
            controller.presentConnectSheet(prefill: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// macOS routes `mumble://…` URLs here both at launch (after
    /// `applicationDidFinishLaunching(_:)` under normal ordering) and while
    /// the app is already running. We pre-populate the Connect sheet rather
    /// than auto-connecting so the user can confirm identity + password
    /// before hitting an unfamiliar server.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let mumbleURL = try MumbleURL.parse(url)
                if !mumbleURL.channelPath.isEmpty {
                    // The reference client auto-joins a channel after ServerSync.
                    // We don't yet, so log the request instead of silently dropping it.
                    let path = mumbleURL.channelPath.joined(separator: "/")
                    Self.log.notice("mumble:// URL specified channel path '\(path, privacy: .public)' — auto-join not implemented")
                }
                if let controller = mainWindowController {
                    controller.presentConnectSheet(prefill: mumbleURL)
                    NSApp.activate()
                } else {
                    // Launch path: remember the URL and replay after
                    // `applicationDidFinishLaunching(_:)` spins up the window.
                    pendingLaunchURL = mumbleURL
                }
            } catch {
                Self.log.warning("Ignoring malformed mumble:// URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc func showCertificateManager(_ sender: Any?) {
        if certificateManagerController == nil {
            certificateManagerController = CertificateManagerWindowController()
        }
        guard let controller = certificateManagerController else { return }
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
