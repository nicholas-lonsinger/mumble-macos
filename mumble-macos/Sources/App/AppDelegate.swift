import AppKit
import OSLog
import UniformTypeIdentifiers

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
        Task { @MainActor in
            let status = await PublicServerRefresh.shared.run(defaultUsername: username)
            switch status {
            case .finished(let count):
                self.presentRefreshSuccess(count: count)
            case .failed(let message):
                self.presentRefreshFailure(message: message)
            case .idle, .running:
                // .running can happen if the user double-clicked; no UI
                // for that — the in-flight refresh will show its result
                // when it lands.
                break
            }
        }
    }

    private func presentRefreshSuccess(count: Int) {
        let alert = NSAlert()
        alert.messageText = "Refreshed public servers"
        alert.informativeText = "Imported \(count) server\(count == 1 ? "" : "s") from publist.mumble.info."
        alert.alertStyle = .informational
        presentAlertSheet(alert)
    }

    private func presentRefreshFailure(message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't refresh public servers"
        alert.informativeText = message
        alert.alertStyle = .warning
        presentAlertSheet(alert)
    }

    /// One-shot import of the reference Mumble client's bookmarks. NSOpenPanel
    /// gives us read access to the user-selected `mumble.sqlite` even from
    /// inside the sandbox (entitlement
    /// `com.apple.security.files.user-selected.read-write`).
    @objc func importFromMumbleApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import from Mumble.app"
        panel.message = "Choose mumble.sqlite — typically at ~/Library/Application Support/Mumble/Mumble/."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if let sqliteType = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqliteType]
        }
        panel.directoryURL = Self.likelyMumbleDataDirectory()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                self.runMumbleAppImport(at: url)
            }
        }
    }

    private func runMumbleAppImport(at url: URL) {
        do {
            let summary = try MumbleAppImportCoordinator().run(at: url)
            presentImportSuccess(summary: summary)
        } catch {
            presentImportFailure(error: error)
        }
    }

    /// Best-effort path to the reference client's data dir. Sandboxed apps'
    /// `NSHomeDirectory()` rewrites to the container, so we ask the OS for
    /// the real user record. Used only as a hint — NSOpenPanel will let
    /// the user navigate anywhere if we guess wrong.
    private static func likelyMumbleDataDirectory() -> URL? {
        let realHomePath: String? = {
            if let pw = getpwuid(getuid()) {
                return String(cString: pw.pointee.pw_dir)
            }
            return NSHomeDirectoryForUser(NSUserName())
        }()
        guard let realHomePath else { return nil }
        return URL(fileURLWithPath: realHomePath, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Mumble/Mumble", isDirectory: true)
    }

    private func presentImportSuccess(summary: MumbleAppImportCoordinator.Summary) {
        let alert = NSAlert()
        let total = summary.imported
        alert.messageText = "Imported \(total) server\(total == 1 ? "" : "s")"
        var lines: [String] = []
        if summary.skippedDuplicates > 0 {
            lines.append("Skipped \(summary.skippedDuplicates) duplicate\(summary.skippedDuplicates == 1 ? "" : "s") (host, port, and username already saved).")
        }
        if summary.passwordWriteFailures > 0 {
            lines.append("\(summary.passwordWriteFailures) password\(summary.passwordWriteFailures == 1 ? "" : "s") couldn't be saved to the keychain — those bookmarks now have \"Remember password\" turned off.")
        }
        if lines.isEmpty {
            lines.append("New entries land in the \"Imported\" group.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        presentAlertSheet(alert)
    }

    private func presentImportFailure(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't import from Mumble.app"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        presentAlertSheet(alert)
    }

    /// Attaches `alert` as a sheet on whichever window is currently key,
    /// falling back to a plain modal if no window is up. Sheets feel more
    /// macOS-native than full-app modals and don't obscure the rest of
    /// the UI while the user reads the result.
    private func presentAlertSheet(_ alert: NSAlert) {
        let target = NSApp.keyWindow
            ?? serversWindowController?.window
            ?? mainWindowController?.window
        if let target {
            alert.beginSheetModal(for: target) { _ in }
        } else {
            alert.runModal()
        }
    }
}
