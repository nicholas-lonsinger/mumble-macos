import AppKit

@MainActor
enum MainMenuBuilder {
	static func install(on app: NSApplication) {
		let mainMenu = NSMenu()
		let appMenuItem = NSMenuItem()
		mainMenu.addItem(appMenuItem)
		appMenuItem.submenu = buildAppMenu(app: app)

		let editMenuItem = NSMenuItem()
		mainMenu.addItem(editMenuItem)
		editMenuItem.submenu = buildEditMenu()

		let windowMenuItem = NSMenuItem()
		mainMenu.addItem(windowMenuItem)
		let windowMenu = buildWindowMenu()
		windowMenuItem.submenu = windowMenu
		app.windowsMenu = windowMenu

		let helpMenuItem = NSMenuItem()
		mainMenu.addItem(helpMenuItem)
		helpMenuItem.submenu = buildHelpMenu()

		app.mainMenu = mainMenu
	}

	private static func buildAppMenu(app: NSApplication) -> NSMenu {
		let menu = NSMenu(title: "Mumble")
		menu.addItem(withTitle: "About Mumble",
					 action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
					 keyEquivalent: "")
		menu.addItem(NSMenuItem.separator())

		let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
		let servicesMenu = NSMenu(title: "Services")
		servicesItem.submenu = servicesMenu
		menu.addItem(servicesItem)
		app.servicesMenu = servicesMenu

		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: "Hide Mumble",
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
		menu.addItem(withTitle: "Quit Mumble",
					 action: #selector(NSApplication.terminate(_:)),
					 keyEquivalent: "q")
		return menu
	}

	private static func buildEditMenu() -> NSMenu {
		let menu = NSMenu(title: "Edit")
		menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
		let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
		redo.keyEquivalentModifierMask = [.command, .shift]
		menu.addItem(redo)
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		menu.addItem(withTitle: "Select All",
					 action: #selector(NSResponder.selectAll(_:)),
					 keyEquivalent: "a")
		return menu
	}

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
		return menu
	}

	private static func buildHelpMenu() -> NSMenu {
		return NSMenu(title: "Help")
	}
}
