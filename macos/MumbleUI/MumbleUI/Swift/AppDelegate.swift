import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var mainWindowController: MainWindowController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		let controller = MainWindowController()
		controller.showWindow(nil)
		mainWindowController = controller
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		return true
	}
}
