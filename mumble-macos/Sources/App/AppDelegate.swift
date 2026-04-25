import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared `MumbleClient` lives at app scope so both the main
    /// window and the Servers window dispatch into the same client.
    let client = MumbleClient()

    private var mainWindowController: MainWindowController?
    private var serversWindowController: ServersWindowController?
    private var certificateManagerController: CertificateManagerWindowController?
    /// A URL that arrived before `applicationDidFinishLaunching(_:)` created
    /// the main window. Replayed once the window exists.
    private var pendingLaunchURL: MumbleURL?

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let controller = MainWindowController(client: client)
        controller.showWindow(nil)
        mainWindowController = controller

        NSApp.activate()

        if let url = pendingLaunchURL {
            pendingLaunchURL = nil
            controller.presentQuickConnectSheet(prefill: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// macOS routes `mumble://…` URLs here both at launch (after
    /// `applicationDidFinishLaunching(_:)` under normal ordering) and while
    /// the app is already running. We pre-populate the Quick Connect sheet
    /// rather than auto-connecting so the user can confirm identity +
    /// password before hitting an unfamiliar server.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let mumbleURL = try MumbleURL.parse(url)
                Self.log.info("Received mumble:// URL host=\(mumbleURL.host, privacy: .public):\(mumbleURL.port, privacy: .public) channel=\(mumbleURL.channelPath.joined(separator: "/"), privacy: .public)")
                if let controller = mainWindowController {
                    NSApp.activate()
                    controller.presentQuickConnectSheet(prefill: mumbleURL)
                } else {
                    pendingLaunchURL = mumbleURL
                }
            } catch {
                let safe = MumbleURL.redactingPassword(url)
                Self.log.warning("Ignoring malformed mumble:// URL \(safe, privacy: .public): \(String(describing: error), privacy: .public)")
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

    @objc func showServersWindow(_ sender: Any?) {
        if serversWindowController == nil {
            serversWindowController = ServersWindowController(
                client: client,
                mainWindow: mainWindowController?.window
            )
        }
        guard let controller = serversWindowController else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Triggers a refresh of the seeded public-servers group. Pulls the
    /// preferred username from the same `@AppStorage` key the Connect form
    /// uses; the user can override it per-server later.
    @objc func refreshPublicServers(_ sender: Any?) {
        let username = UserDefaults.standard.string(forKey: "lastServerUsername") ?? ""
        PublicServerRefresh.shared.start(defaultUsername: username)
    }
}
