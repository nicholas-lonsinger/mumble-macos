import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
	convenience init() {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "Mumble"
		window.contentViewController = NSHostingController(rootView: HelloView())
		window.center()
		self.init(window: window)
	}
}
