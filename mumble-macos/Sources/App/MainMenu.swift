import AppKit

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let menubar = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = buildAppMenu()
        menubar.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = buildFileMenu()
        menubar.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = buildEditMenu()
        menubar.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = buildViewMenu()
        menubar.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = buildWindowMenu()
        menubar.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = buildHelpMenu()
        menubar.addItem(helpMenuItem)

        return menubar
    }

    @MainActor
    private static func buildAppMenu() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu()

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(AppDelegate.showAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Certificate Manager…",
                     action: #selector(AppDelegate.showCertificateManager(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Preferences…",
                     action: #selector(AppDelegate.showPreferences(_:)),
                     keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Hide \(appName)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    @MainActor
    private static func buildFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Servers…",
                     action: #selector(AppDelegate.showServersWindow(_:)),
                     keyEquivalent: "k")
        let quickConnect = NSMenuItem(
            title: "Quick Connect…",
            action: #selector(MainWindowController.showQuickConnectSheet(_:)),
            keyEquivalent: "k"
        )
        quickConnect.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(quickConnect)
        menu.addItem(withTitle: "Disconnect",
                     action: #selector(MainWindowController.disconnect(_:)),
                     keyEquivalent: "d")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Refresh Public Servers",
                     action: #selector(AppDelegate.refreshPublicServers(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Import from Mumble.app…",
                     action: #selector(AppDelegate.importFromMumbleApp(_:)),
                     keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        return menu
    }

    @MainActor
    private static func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        return menu
    }

    @MainActor
    private static func buildViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    @MainActor
    private static func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }

    @MainActor
    private static func buildHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        NSApp.helpMenu = menu
        return menu
    }
}
